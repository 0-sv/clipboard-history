import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ClipKind: String, Sendable {
    case text, image, file
}

public struct ClipItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let kind: ClipKind
    public let preview: String
    public let imagePath: String?
    public let appName: String?
    public let usedAt: Date
    public let pinned: Bool
    public let byteSize: Int
}

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

public final class Store {
    public static let previewLength = 300
    // The FTS index only covers the head of very large entries, so one huge copy cannot bloat it.
    static let indexedLength = 100_000

    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(description: "cannot open \(path): \(lastError)")
        }
        try run("PRAGMA journal_mode=WAL")
        try run("""
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                image_path TEXT,
                hash TEXT NOT NULL UNIQUE,
                app_name TEXT,
                app_bundle TEXT,
                created_at REAL NOT NULL,
                used_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                byte_size INTEGER NOT NULL DEFAULT 0
            )
            """)
        try run("CREATE INDEX IF NOT EXISTS items_order ON items(pinned DESC, used_at DESC)")
        try run("CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(text, tokenize='trigram')")
    }

    deinit {
        sqlite3_close(db)
    }

    public static func hash(kind: ClipKind, data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func insert(
        kind: ClipKind,
        text: String,
        imagePath: String? = nil,
        hash: String,
        appName: String? = nil,
        appBundle: String? = nil,
        byteSize: Int,
        now: Date = Date()
    ) throws -> Int64 {
        let timestamp = now.timeIntervalSince1970
        var existing: Int64?
        try run("SELECT id FROM items WHERE hash = ?", [hash]) { existing = sqlite3_column_int64($0, 0) }
        if let existing {
            try run("UPDATE items SET used_at = ? WHERE id = ?", [timestamp, existing])
            return existing
        }
        try run(
            """
            INSERT INTO items(kind, text, image_path, hash, app_name, app_bundle, created_at, used_at, byte_size)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [kind.rawValue, text, imagePath, hash, appName, appBundle, timestamp, timestamp, byteSize]
        )
        let id = sqlite3_last_insert_rowid(db)
        try run("INSERT INTO items_fts(rowid, text) VALUES (?, ?)", [id, String(text.prefix(Self.indexedLength))])
        return id
    }

    public func search(_ query: String, limit: Int = 100, offset: Int = 0) throws -> [ClipItem] {
        let columns = """
            items.id, items.kind, substr(items.text, 1, \(Self.previewLength)), items.image_path,
            items.app_name, items.used_at, items.pinned, items.byte_size
            """
        let order = "ORDER BY items.pinned DESC, items.used_at DESC LIMIT ? OFFSET ?"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        var sql: String
        var params: [Any?]
        if terms.isEmpty {
            sql = "SELECT \(columns) FROM items \(order)"
            params = []
        } else if terms.allSatisfy({ $0.count >= 3 }) {
            let match = terms
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            sql = """
                SELECT \(columns) FROM items_fts JOIN items ON items.id = items_fts.rowid
                WHERE items_fts MATCH ? \(order)
                """
            params = [match]
        } else {
            // The trigram tokenizer cannot match terms under 3 characters.
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sql = "SELECT \(columns) FROM items WHERE items.text LIKE ? ESCAPE '\\' \(order)"
            params = ["%\(escaped)%"]
        }
        params += [limit, offset]

        var items: [ClipItem] = []
        try run(sql, params) { row in
            items.append(ClipItem(
                id: sqlite3_column_int64(row, 0),
                kind: ClipKind(rawValue: Self.string(row, 1) ?? "") ?? .text,
                preview: Self.string(row, 2) ?? "",
                imagePath: Self.string(row, 3),
                appName: Self.string(row, 4),
                usedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                pinned: sqlite3_column_int(row, 6) != 0,
                byteSize: Int(sqlite3_column_int64(row, 7))
            ))
        }
        return items
    }

    public func fullText(id: Int64, maxLength: Int? = nil) throws -> String? {
        var text: String?
        if let maxLength {
            try run("SELECT substr(text, 1, ?) FROM items WHERE id = ?", [maxLength, id]) { text = Self.string($0, 0) }
        } else {
            try run("SELECT text FROM items WHERE id = ?", [id]) { text = Self.string($0, 0) }
        }
        return text
    }

    public func count() throws -> Int {
        var total = 0
        try run("SELECT count(*) FROM items") { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    public func touch(id: Int64, now: Date = Date()) throws {
        try run("UPDATE items SET used_at = ? WHERE id = ?", [now.timeIntervalSince1970, id])
    }

    public func togglePin(id: Int64) throws {
        try run("UPDATE items SET pinned = 1 - pinned WHERE id = ?", [id])
    }

    public func delete(id: Int64) throws {
        try deleteWhere("id = ?", [id])
    }

    @discardableResult
    public func deleteSince(_ date: Date) throws -> Int {
        try deleteWhere("created_at >= ? AND pinned = 0", [date.timeIntervalSince1970])
    }

    @discardableResult
    public func clear(keepPinned: Bool = true) throws -> Int {
        try deleteWhere(keepPinned ? "pinned = 0" : "1 = 1", [])
    }

    @discardableResult
    private func deleteWhere(_ condition: String, _ params: [Any?]) throws -> Int {
        var imagePaths: [String] = []
        try run("SELECT image_path FROM items WHERE \(condition) AND image_path IS NOT NULL", params) {
            if let path = Self.string($0, 0) { imagePaths.append(path) }
        }
        try run("DELETE FROM items_fts WHERE rowid IN (SELECT id FROM items WHERE \(condition))", params)
        try run("DELETE FROM items WHERE \(condition)", params)
        let deleted = Int(sqlite3_changes(db))
        for path in imagePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        return deleted
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private func run(_ sql: String, _ params: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError(description: "prepare failed: \(lastError)")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case nil: sqlite3_bind_null(statement, index)
            default: throw StoreError(description: "unsupported parameter at \(index)")
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return
            default: throw StoreError(description: "step failed: \(lastError)")
            }
        }
    }
}
