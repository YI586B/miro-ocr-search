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
    private var readTask: Task<Void, Never>?
    @Published var query = ""
    @Published var searchMode: SearchMode = SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .phrase {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode") }
    }
    @Published var results: [Hit] = []
    @Published var selection = Set<String>()
    @Published var status = "Index a folder to get started."
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
        readTask?.cancel()
        folder = url
        docs = []; results = []; selection = []
        let images = (FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .filter { imageExts.contains($0.pathExtension.lowercased()) } ?? []).sorted { $0.path < $1.path }

        guard !images.isEmpty else {
            status = "No images in \(url.lastPathComponent)"; reading = nil; return
        }
        busy = true; reading = (0, images.count)
        status = "Reading \(plural(images.count, "image")) in \(url.lastPathComponent)…"

        readTask = Task { [weak self] in
            var out: [Doc] = []
            // Bounded concurrency: Vision is happy to use every core, but spawning one task per
            // file on a large folder just thrashes.
            let lanes = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
            var next = 0
            await withTaskGroup(of: Doc?.self) { group in
                func submit() {
                    guard next < images.count else { return }
                    let u = images[next]; next += 1
                    group.addTask(priority: .userInitiated) {
                        guard let text = try? recognizeText(at: u) else { return nil }
                        return Doc(path: u.path, text: text)
                    }
                }
                for _ in 0..<lanes { submit() }
                while let doc = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let doc { out.append(doc) }
                    await MainActor.run { self?.reading = (out.count, images.count) }
                    submit()
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.docs = out.sorted { $0.path < $1.path }
                self.reading = nil; self.busy = false
                let failed = images.count - out.count
                self.status = failed == 0
                    ? "Read \(plural(out.count, "image")) in \(url.lastPathComponent)"
                    : "Read \(plural(out.count, "image")) in \(url.lastPathComponent), \(failed) unreadable"
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

    func exportToFile(_ format: FileFormat) {
        let hits = results.filter { selection.contains($0.path) }
        guard !hits.isEmpty else { return }
        do {
            switch format {
            case .csv, .markdown:
                let panel = NSSavePanel()
                let isCSV = format == .csv
                panel.nameFieldStringValue = isCSV ? "ocr-results.csv" : "ocr-results.md"
                panel.allowedContentTypes = [isCSV ? .commaSeparatedText : UTType(filenameExtension: "md") ?? .plainText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
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
                try out.write(to: url, atomically: true, encoding: .utf8)
                status = "Saved \(hits.count) item(s) to \(url.lastPathComponent)"
            case .images:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.prompt = "Export here"
                panel.message = "Choose where to write the images, with their overlays and watermark."
                guard panel.runModal() == .OK, let dir = panel.url else { return }
                renderImages(hits, into: dir)
            }
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
