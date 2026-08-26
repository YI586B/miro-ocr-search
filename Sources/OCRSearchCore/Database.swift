// The SQLite FTS5 index is used by the ocrsearch CLI only. The app searches the open folder in
// memory and uses nothing here except SearchMode.
import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Whether a multi-word query should match as one contiguous phrase, or as separate words that
/// can appear anywhere (and in any order) in the text.
public enum SearchMode: String, CaseIterable, Sendable, Codable { case phrase, words }

/// Turn a plain, unquoted query into an FTS5 MATCH expression for the given mode. A query that
/// already uses explicit FTS5 syntax (quotes, AND/OR/NOT/NEAR, parentheses, a `*` wildcard) is
/// passed through untouched in either mode, so that still works for anyone who types it.
/// Otherwise `.phrase` wraps the whole query in quotes so "screen active" only matches that
/// exact phrase, while `.words` leaves it as FTS5's default implicit AND of separate words.
public func ftsQuery(_ raw: String, mode: SearchMode) -> String {
    let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard mode == .phrase, !looksLikeAdvancedFTS(q) else { return q }
    return "\"\(q.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func looksLikeAdvancedFTS(_ q: String) -> Bool {
    if q.contains("\"") || q.contains("(") || q.contains(")") || q.contains("*") { return true }
    let upper = q.uppercased()
    return ["AND", "OR", "NOT", "NEAR"].contains { upper.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
}

/// SQLite + FTS5 store: `files` tracks what was indexed, `fts` holds searchable text.
public final class Database {
    private var db: OpaquePointer?

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw err() }
        try exec("""
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            path UNINDEXED, text, tokenize='unicode61 remove_diacritics 2');
        """)
    }
    deinit { sqlite3_close(db) }

    private func err() -> NSError {
        NSError(domain: "sqlite", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw err() }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { throw err() }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw err() }
    }

    public func mtime(of path: String) -> Double? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT mtime FROM files WHERE path=?", -1, &st, nil) == SQLITE_OK,
              let s = st else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, path, -1, TRANSIENT)
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_double(s, 0) : nil
    }

    public func upsert(path: String, mtime: Double, text: String) throws {
        try run("DELETE FROM fts WHERE path=?") { sqlite3_bind_text($0, 1, path, -1, TRANSIENT) }
        try run("INSERT INTO fts(path,text) VALUES(?,?)") {
            sqlite3_bind_text($0, 1, path, -1, TRANSIENT)
            sqlite3_bind_text($0, 2, text, -1, TRANSIENT)
        }
        try run("INSERT OR REPLACE INTO files(path,mtime) VALUES(?,?)") {
            sqlite3_bind_text($0, 1, path, -1, TRANSIENT)
            sqlite3_bind_double($0, 2, mtime)
        }
    }

    /// Full OCR text stored for a file, if it has been indexed.
    public func text(of path: String) -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM fts WHERE path=?", -1, &st, nil) == SQLITE_OK,
              let s = st else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, path, -1, TRANSIENT)
        guard sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: c)
    }

    public func search(_ query: String, limit: Int = 20) throws -> [(path: String, snippet: String)] {
        var st: OpaquePointer?
        let sql = """
        SELECT path, snippet(fts, 1, '[', ']', '…', 12) FROM fts
        WHERE fts MATCH ? ORDER BY rank LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { throw err() }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, query, -1, TRANSIENT)
        sqlite3_bind_int(s, 2, Int32(limit))
        var out: [(String, String)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(s, 0)),
                        String(cString: sqlite3_column_text(s, 1)).replacingOccurrences(of: "\n", with: " ")))
        }
        return out
    }
}
