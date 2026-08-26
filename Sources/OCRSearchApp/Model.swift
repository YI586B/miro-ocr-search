import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OCRSearchCore

/// "1 result" / "2 results" — every status message below used to print the literal string
/// "result(s)", which reads as a debug placeholder rather than finished copy.
func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

struct Hit: Identifiable, Hashable {
    let path: String
    var snippet: String
    var id: String { path }
}

/// One image in the open folder, with the text read off it. Held in memory for as long as the
/// folder is open and no longer than that.
struct Doc: Sendable {
    let path: String
    let text: String
}

@MainActor
final class Model: ObservableObject {
    /// The folder being searched. Everything comes from here: there is no index and no database,
    /// so what you search is exactly what is in the folder you picked, as it is right now.
    @Published var folder: URL? {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "folder") }
    }
    /// Every image in that folder, with its text. Rebuilt when the folder is opened or reloaded.
    private var docs: [Doc] = []
    /// Progress while reading a folder — (done, total) — for the status line.
    @Published var reading: (done: Int, total: Int)?
    /// Bumped by each open(folder:). A read in flight checks it and gives up once it is no longer
    /// the current one, which is how a folder change cancels the previous read.
    private var readGeneration = 0

    /// Where the OCR runs.
    ///
    /// Deliberately a Dispatch queue rather than Swift Concurrency. recognizeText blocks the
    /// thread it is on for as long as Vision takes, and Vision funnels requests through a capacity
    /// queue of its own with a *synchronous* dispatch. Running several of those on the cooperative
    /// pool — which has about one thread per core — parked every thread it had inside that
    /// synchronous wait, leaving nothing able to make progress: sampled while stuck, nine threads
    /// sat in dispatchSyncByPreservingQueueCapacity waiting for queue ownership that was never
    /// going to arrive.
    ///
    /// Serial, because concurrency barely helps and this is where the trouble came from. Running
    /// three of these at once on a Dispatch queue — which, unlike the cooperative pool, can grow
    /// threads to cover blocking work — read this folder in 9.9s against 11.1s serial. An 11%
    /// gain is not worth contending again on the queue that deadlocked, since Vision serialises
    /// the requests internally regardless.
    private static let readQueue = DispatchQueue(label: "com.sir.ocr-search.read", qos: .userInitiated)
    @Published var query = ""
    @Published var searchMode: SearchMode = SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .phrase {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode") }
    }
    @Published var results: [Hit] = []
    @Published var selection = Set<String>()
    @Published var status = "Open a folder to get started."
    @Published var busy = false
    @Published var boardID = ""
    @Published var boardName = "OCR search"
    @Published var link: URL?
    /// Set when an export fails, so the export sheet can show the reason inline instead of the
    /// user only finding out from a status line in a window that's now behind the sheet.
    @Published var exportError: String?
    @Published var token: String = Keychain.get("miro-token") ?? "" {
        didSet { Keychain.set("miro-token", token) }
    }

    /// Matches the query against the text already read from the folder — a substring scan over a
    /// few dozen strings, so it runs on every keystroke without a second thought.
    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        let manual = results.filter { $0.snippet.isEmpty && selection.contains($0.path) }  // keep added files
        guard !q.isEmpty else { results = manual; return }
        let terms = searchTerms(q, mode: searchMode)
        guard !terms.isEmpty else { results = manual; return }

        let hits = docs.compactMap { doc -> Hit? in
            // .phrase gives one term (the whole query, matched contiguously); .words gives one
            // term per word, all of which have to appear somewhere. Same rule the preview window
            // highlights by, so what is listed and what is boxed on the image agree.
            let found = terms.compactMap { doc.text.range(of: $0, options: .caseInsensitive) }
            guard found.count == terms.count, let first = found.min(by: { $0.lowerBound < $1.lowerBound })
            else { return nil }
            return Hit(path: doc.path, snippet: snippet(doc.text, around: first))
        }
        results = hits + manual
        status = folder == nil ? plural(results.count, "result")
            : "\(plural(results.count, "result")) in \(folder!.lastPathComponent)"
    }

    /// A line of context around the match, with the match itself bracketed — the same shape the
    /// result rows showed when this came out of the database.
    private func snippet(_ text: String, around match: Range<String.Index>) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let m = flat.range(of: String(text[match]), options: .caseInsensitive) else { return flat }
        let pad = 60
        let lo = flat.index(m.lowerBound, offsetBy: -pad, limitedBy: flat.startIndex) ?? flat.startIndex
        let hi = flat.index(m.upperBound, offsetBy: pad, limitedBy: flat.endIndex) ?? flat.endIndex
        return (lo == flat.startIndex ? "" : "…") + flat[lo..<m.lowerBound]
            + "[" + flat[m] + "]" + flat[m.upperBound..<hi] + (hi == flat.endIndex ? "" : "…")
    }

    /// Reads every image in `url` and keeps the text in memory for as long as it stays open.
    ///
    /// The whole folder is read up front rather than on demand because the alternative is running
    /// OCR inside the search, which would make every keystroke cost seconds. Reading is the slow
    /// part and it happens once, visibly, with a count; searching afterwards is instant.
    func open(folder url: URL) {
        reading = nil
        readGeneration += 1
        folder = url
        docs = []; results = []; selection = []
        let images = (FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .filter { imageExts.contains($0.pathExtension.lowercased()) } ?? []).sorted { $0.path < $1.path }

        guard !images.isEmpty else {
            status = "No images in \(url.lastPathComponent)"; reading = nil; busy = false; return
        }
        busy = true; reading = (0, images.count)
        status = "Reading \(plural(images.count, "image")) in \(url.lastPathComponent)…"

        let generation = readGeneration
        Self.readQueue.async { [weak self] in
            var out: [Doc] = []
            var done = 0
            for u in images {
                // A newer open(folder:) supersedes this one; stop rather than finish work whose
                // results would be thrown away.
                var stale = false
                DispatchQueue.main.sync { stale = self?.readGeneration != generation }
                if stale { return }

                if let text = try? recognizeText(at: u) { out.append(Doc(path: u.path, text: text)) }
                done += 1
                let progress = done
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.readGeneration == generation else { return }
                    self.reading = (progress, images.count)
                }
            }
            let docs = out
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readGeneration == generation else { return }
                self.docs = docs
                self.reading = nil; self.busy = false
                let failed = images.count - docs.count
                self.status = failed == 0
                    ? "Read \(plural(docs.count, "image")) in \(url.lastPathComponent)"
                    : "Read \(plural(docs.count, "image")) in \(url.lastPathComponent), \(failed) unreadable"
                self.search()
            }
        }
    }

    /// Re-reads the open folder, picking up anything added or changed since.
    func reload() { if let folder { open(folder: folder) } }

    /// Reopens whatever folder was last used, on launch.
    func restoreFolder() {
        guard folder == nil, let p = UserDefaults.standard.string(forKey: "folder"),
              FileManager.default.fileExists(atPath: p) else { return }
        open(folder: URL(fileURLWithPath: p))
    }

    func add(files: [URL]) {
        for u in files where !results.contains(where: { $0.path == u.path }) {
            results.append(Hit(path: u.path, snippet: "")); selection.insert(u.path)
        }
    }

    func exportSelection() {
        let items = results.filter { selection.contains($0.path) }.map { (path: $0.path, snippet: $0.snippet) }
        guard !items.isEmpty else { return }
        guard !token.isEmpty else {
            status = "Enter your Miro token first."; exportError = "Enter your Miro token first."; return
        }
        busy = true; link = nil; exportError = nil; status = "Exporting \(plural(items.count, "item")) to Miro…"
        let (tok, id, name) = (token, boardID.trimmingCharacters(in: .whitespaces), boardName)
        let (q, sm) = (query, searchMode)
        let style = OverlayStyle.current()
        Task.detached {
            do {
                // A board full of untouched screenshots would lose the very thing the search
                // found, so what goes up is the composited image — the same render the folder
                // export writes — staged in a temp directory the upload reads from. Anything that
                // fails to render still goes up as its original rather than being dropped.
                let staged = renderForUpload(items, query: q, searchMode: sm, style: style)
                let l = try exportToMiro(items: staged, token: tok, boardID: id.isEmpty ? nil : id,
                                         boardName: name, log: { _ in })
                await MainActor.run { self.link = URL(string: l); self.status = "Exported \(plural(items.count, "item"))."; self.busy = false }
            } catch {
                await MainActor.run {
                    self.status = "Miro export failed: \(error.localizedDescription)"
                    self.exportError = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    // MARK: export to file

    enum FileFormat { case csv, markdown, images }

    private func fullText(_ hit: Hit) -> String {
        docs.first { $0.path == hit.path }?.text
            ?? (try? recognizeText(at: URL(fileURLWithPath: hit.path)))   // a file added by hand
            ?? hit.snippet
    }

    /// Shows a panel without starting a nested modal run loop, and not until the next turn of the
    /// run loop either.
    ///
    /// Every one of these is invoked from a Menu item. runModal() spins its own modal loop, and
    /// starting one while AppKit is still unwinding the menu's tracking loop wedges the app — the
    /// window stops responding and there is no crash report, because nothing crashed. begin()
    /// presents the same panel modelessly and calls back instead. (NSOpenPanel is an NSSavePanel,
    /// so this covers both.)
    private func present(_ panel: NSSavePanel, _ done: @escaping () -> Void) {
        DispatchQueue.main.async {
            panel.begin { if $0 == .OK { done() } }
        }
    }

    func exportToFile(_ format: FileFormat) {
        let hits = results.filter { selection.contains($0.path) }
        guard !hits.isEmpty else { return }
        switch format {
        case .csv, .markdown:
            let isCSV = format == .csv
            let panel = Panels.save
            panel.nameFieldStringValue = isCSV ? "ocr-results.csv" : "ocr-results.md"
            panel.allowedContentTypes = [isCSV ? .commaSeparatedText : UTType(filenameExtension: "md") ?? .plainText]
            present(panel) { [weak self] in
                guard let self, let url = panel.url else { return }
                self.writeText(hits, isCSV: isCSV, to: url)
            }
        case .images:
            let panel = Panels.openPanel(dir: true)
            panel.canCreateDirectories = true
            panel.prompt = "Export here"
            panel.message = "Choose where to write the images, with their overlays and watermark."
            present(panel) { [weak self] in
                guard let self, let dir = panel.url else { return }
                self.renderImages(hits, into: dir)
            }
        }
    }

    private func writeText(_ hits: [Hit], isCSV: Bool, to url: URL) {
        var out = ""
        if isCSV {
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            out = "path,filename,text\n" + hits.map {
                [q($0.path), q(($0.path as NSString).lastPathComponent), q(fullText($0))].joined(separator: ",")
            }.joined(separator: "\n") + "\n"
        } else {
            out = "# OCR search results\n\n" + hits.map {
                let t = fullText($0).split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                return "## \(($0.path as NSString).lastPathComponent)\n\n`\($0.path)`\n\n\(t)\n"
            }.joined(separator: "\n")
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(plural(hits.count, "item")) to \(url.lastPathComponent)"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }

    /// Writes each selected image into `dir` with its overlays and watermark composited in, at
    /// the image's own resolution (see renderExportPNG). Runs off the main actor because each
    /// image is a fresh OCR pass plus colour sampling and font matching — a second or two apiece,
    /// which would otherwise freeze the window for the length of the whole batch.
    private func renderImages(_ hits: [Hit], into dir: URL) {
        busy = true; status = "Rendering \(plural(hits.count, "image"))…"
        let jobs = hits.map(\.path)
        let (q, sm) = (query, searchMode)
        let style = OverlayStyle.current()
        Task.detached(priority: .userInitiated) {
            var written = 0, failed = 0
            for (i, path) in jobs.enumerated() {
                await MainActor.run { self.status = "Rendering \(i + 1) of \(jobs.count)…" }
                guard let data = renderExportPNG(path: path, query: q, searchMode: sm, style: style) else {
                    failed += 1; continue
                }
                // Always .png, whatever the source was; see renderExportPNG. The suffix keeps an
                // export next to its original from silently overwriting it when the source was
                // already a PNG, which a plain extension swap would do.
                let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                var dest = dir.appendingPathComponent("\(base)-overlay.png"), n = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(base)-overlay-\(n).png"); n += 1
                }
                do { try data.write(to: dest); written += 1 } catch { failed += 1 }
            }
            let (w, f) = (written, failed)
            await MainActor.run {
                self.status = f == 0
                    ? "Exported \(plural(w, "image")) to \(dir.lastPathComponent)"
                    : "Exported \(plural(w, "image")) to \(dir.lastPathComponent), \(f) failed"
                self.busy = false
            }
        }
    }
}

/// Composites each item for upload and returns the same list pointing at the rendered files.
/// Writes into a per-export temp directory rather than alongside the originals — these are
/// transport artefacts, not something the user asked to keep, and the OS reclaims them.
private func renderForUpload(_ items: [(path: String, snippet: String)], query: String,
                             searchMode: SearchMode, style: OverlayStyle) -> [(path: String, snippet: String)] {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ocrsearch-export-\(UUID().uuidString)")
    guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
    else { return items }
    return items.map { item in
        let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent("\(name).png")
        guard let data = renderExportPNG(path: item.path, query: query, searchMode: searchMode, style: style),
              (try? data.write(to: dest)) != nil else { return item }
        return (path: dest.path, snippet: item.snippet)
    }
}
