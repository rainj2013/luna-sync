import Foundation
import LunaSyncCore

#if os(iOS)
import SQLite3

public struct SessionSummary: Codable, Identifiable, Sendable {
    public let id: UUID
    public let archiveID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let status: String
    public let total: Int
    public let completed: Int
    public let issues: [String: String]
    public init(archiveID: UUID, startedAt: Date, status: String, total: Int, completed: Int, issues: [String: String]) {
        id = UUID(); self.archiveID = archiveID; self.startedAt = startedAt; finishedAt = Date()
        self.status = status; self.total = total; self.completed = completed; self.issues = issues
    }
}

/// Disposable phone-local cache. Failure must never manufacture backup success.
public actor LocalCatalog {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.bfa952c9"))
        }
        do {
            try Self.execute(db, "PRAGMA journal_mode=WAL;")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS assets (archive_id TEXT NOT NULL, asset_key TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(archive_id, asset_key));")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, finished REAL NOT NULL, payload BLOB NOT NULL);")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func rebuild(archiveID: UUID, records: [AssetRecord]) throws {
        try Self.execute(db, "BEGIN IMMEDIATE;")
        do {
            try statement("DELETE FROM assets WHERE archive_id=?;", strings: [archiveID.uuidString])
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO assets(archive_id,asset_key,payload) VALUES(?,?,?);", -1, &insert, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(insert) }
            let encoder = JSONEncoder()
            for record in records {
                try Task.checkCancellation()
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                guard sqlite3_bind_text(insert, 1, archiveID.uuidString, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(insert, 2, record.assetKey, -1, transient) == SQLITE_OK else { throw failure() }
                let data = try encoder.encode(record)
                let bound = data.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32($0.count), transient) }
                guard bound == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            }
            try Self.execute(db, "COMMIT;")
        } catch { try? Self.execute(db, "ROLLBACK;"); throw error }
    }
    public func save(_ summary: SessionSummary) throws {
        try statement("INSERT OR REPLACE INTO sessions(id,finished,payload) VALUES(?,strftime('%s','now'),?);",
                      strings: [summary.id.uuidString], blob: JSONEncoder().encode(summary))
    }
    public func history() throws -> [SessionSummary] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM sessions ORDER BY finished DESC LIMIT 100;", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var summaries: [SessionSummary] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) {
                summaries.append(try JSONDecoder().decode(SessionSummary.self, from: Data(bytes: bytes, count: size)))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return summaries
    }
    private func statement(_ sql: String, strings: [String], blob: Data? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index+1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        if let blob {
            let result = blob.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, Int32(strings.count+1), bytes.baseAddress, Int32(bytes.count), transient) }
            guard result == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func failure() -> BackupFailure {
        .unavailable(BackupCopy.format("diagnostic.dc6f8e05", String(describing: db.map { String(cString: sqlite3_errmsg($0)) } ?? BackupCopy.tr("diagnostic.0e6c9a15"))))
    }
    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.0b3f59b5")) }
    }
}
#endif
