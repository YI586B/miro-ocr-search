import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OCRSearchCore

struct Hit: Identifiable, Hashable {
    let path: String
    var snippet: String
    var id: String { path }
}

@MainActor
final class Model: ObservableObject {
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
    @Published var token: String = Keychain.get("miro-token") ?? "" {
        didSet { Keychain.set("miro-token", token) }
    }

    func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
        do {
            let db = try Database(path: dbPath)
            let manual = results.filter { $0.snippet.isEmpty && selection.contains($0.path) }  // keep added files
            results = try db.search(ftsQuery(query, mode: searchMode), limit: 100).map { Hit(path: $0.path, snippet: $0.snippet) } + manual
            status = "\(results.count) result(s)"
        } catch { status = "Search error: \(error.localizedDescription)" }
    }

    func index(folder: URL) {
        busy = true; status = "Indexing \(folder.lastPathComponent)…"
        Task.detached {
            let r: (Int, Int, Int)
            do { r = indexFolder(folder, db: try Database(path: dbPath), log: { _ in }) }
            catch { await MainActor.run { self.status = "Index error: \(error.localizedDescription)"; self.busy = false }; return }
            await MainActor.run {
                self.status = "Indexed \(r.0) new, \(r.1) unchanged, \(r.2) failed"
                self.busy = false; self.search()
            }
        }
    }

    func add(files: [URL]) {
        for u in files where !results.contains(where: { $0.path == u.path }) {
            results.append(Hit(path: u.path, snippet: "")); selection.insert(u.path)
        }
    }

    func exportSelection() {
        let items = results.filter { selection.contains($0.path) }.map { (path: $0.path, snippet: $0.snippet) }
        guard !items.isEmpty else { return }
        guard !token.isEmpty else { status = "Enter your Miro token first."; return }
        busy = true; link = nil; status = "Exporting \(items.count) item(s) to Miro…"
        let (tok, id, name) = (token, boardID.trimmingCharacters(in: .whitespaces), boardName)
        Task.detached {
            do {
                let l = try exportToMiro(items: items, token: tok, boardID: id.isEmpty ? nil : id,
                                         boardName: name, log: { _ in })
                await MainActor.run { self.link = URL(string: l); self.status = "Exported \(items.count) item(s)."; self.busy = false }
            } catch { await MainActor.run { self.status = "Export failed: \(error)"; self.busy = false } }
        }
    }

    // MARK: export to file

    enum FileFormat { case csv, markdown, folder }

    private func fullText(_ hit: Hit) -> String {
        (try? Database(path: dbPath).text(of: hit.path))
            ?? (try? recognizeText(at: URL(fileURLWithPath: hit.path))) ?? hit.snippet
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
            case .folder:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.prompt = "Copy here"
                guard panel.runModal() == .OK, let dir = panel.url else { return }
                let fm = FileManager.default
                for h in hits {
                    let src = URL(fileURLWithPath: h.path)
                    var dest = dir.appendingPathComponent(src.lastPathComponent), n = 1
                    while fm.fileExists(atPath: dest.path) {
                        dest = dir.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent)-\(n).\(src.pathExtension)"); n += 1
                    }
                    try fm.copyItem(at: src, to: dest)
                }
                status = "Copied \(hits.count) image(s) to \(dir.lastPathComponent)"
            }
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}
