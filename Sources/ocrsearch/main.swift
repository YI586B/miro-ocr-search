import Foundation
import OCRSearchCore

func usage() -> Never {
    print("""
    usage:
      ocrsearch index <folder>       OCR new/changed images and add them to the index
      ocrsearch search <query>       full-text search (FTS5: foo AND "exact phrase" bar*)
      ocrsearch export [query] [--files a.png b.png ...] [--board ID | --name "Board name"] [--limit N]
                                     send search hits and/or chosen files to a Miro board
                                     (needs MIRO_TOKEN; creates a new board unless --board is given)
    """)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

do {
    let db = try Database(path: dbPath)
    switch args[1] {
    case "index":
        let root = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
        let (done, skipped, failed) = indexFolder(root, db: db)
        print("done: \(done) indexed, \(skipped) unchanged, \(failed) failed")
    case "search":
        let q = args.dropFirst(2).joined(separator: " ")
        let hits = try db.search(q)
        if hits.isEmpty { print("no matches") }
        for h in hits { print("\(h.path)\n    \(h.snippet)") }
    case "export":
        var query: [String] = [], files: [String] = []
        var board: String?, name = "OCR search \(ISO8601DateFormatter().string(from: Date()).prefix(10))"
        var limit = 20
        var mode = "q"
        var it = args.dropFirst(2).makeIterator()
        while let a = it.next() {
            switch a {
            case "--files": mode = "f"
            case "--board": board = it.next()
            case "--name": name = it.next() ?? name
            case "--limit": limit = Int(it.next() ?? "") ?? limit
            default: if mode == "f" { files.append((a as NSString).expandingTildeInPath) } else { query.append(a) }
            }
        }
        var items: [(path: String, snippet: String)] = []
        if !query.isEmpty { items += try db.search(query.joined(separator: " "), limit: limit) }
        for f in files where !items.contains(where: { $0.path == f }) {
            items.append((f, ""))       // explicitly chosen files: image only, no snippet
        }
        if items.isEmpty { print("nothing to export"); exit(1) }
        guard let token = ProcessInfo.processInfo.environment["MIRO_TOKEN"], !token.isEmpty else {
            print("error: set MIRO_TOKEN to a Miro access token (boards:read, boards:write)"); exit(2)
        }
        let link = try exportToMiro(items: items, token: token, boardID: board, boardName: name)
        print("board: \(link)")
    default: usage()
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(2)
}
