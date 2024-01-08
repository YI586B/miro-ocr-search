import Foundation

public let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"]
public let dbPath = NSHomeDirectory() + "/Library/Application Support/ocrsearch/index.db"

/// OCR every new/changed image under `root` into the index. Returns (indexed, unchanged, failed).
@discardableResult
public func indexFolder(_ root: URL, db: Database, log: (String) -> Void = { print($0) }) -> (Int, Int, Int) {
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]) else { return (0, 0, 0) }
    var done = 0, skipped = 0, failed = 0
    for case let url as URL in walker where imageExts.contains(url.pathExtension.lowercased()) {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        if db.mtime(of: url.path) == m { skipped += 1; continue }
        do {
            try db.upsert(path: url.path, mtime: m, text: try recognizeText(at: url))
            done += 1; log("indexed \(url.path)")
        } catch { failed += 1; log("failed  \(url.path): \(error)") }
    }
    return (done, skipped, failed)
}
