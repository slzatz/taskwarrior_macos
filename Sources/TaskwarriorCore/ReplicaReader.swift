import Foundation
import SQLite3

/// The two sync facts the `task` CLI doesn't give (`task stats` counts operations, and nothing
/// tells the base version), read straight from taskchampion's database, read-only.
public struct ReplicaState: Equatable, Sendable {
    /// The last server version this replica has; the nil UUID before its first sync.
    public var baseVersion: String
    public var unsyncedTasks: Int
}

public enum ReplicaReader {
    public static let fileName = "taskchampion.sqlite3"
    /// taskchampion's base version before the first sync, when `sync_meta` has no row.
    static let nilVersion = "00000000-0000-0000-0000-000000000000"

    /// Reads `taskchampion.sqlite3` in `dataDirectory` (`data.location`). Nil when the file is
    /// missing, locked past the busy timeout, or its schema isn't the one expected: the
    /// indicator then shows nothing rather than a wrong number.
    public static func read(dataDirectory: String) -> ReplicaState? {
        let path = (NSString(string: dataDirectory).expandingTildeInPath as NSString).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // The database is in WAL mode, and a read-only connection can't create the shared-memory
        // file WAL readers need, which `task` removes as it exits: SQLITE_OPEN_READONLY fails
        // (error 14) whenever no `task` is running. So open read-write, never create, and make
        // the connection refuse writes itself.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db,
              sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else { return nil }
        // Apple's SQLite keeps the -wal and -shm files after the last connection closes; remove
        // them on close, as `task` does, rather than leave them in the user's data directory.
        var persistWAL: Int32 = 0
        sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
        sqlite3_busy_timeout(db, 2000)
        // One read transaction, so the two answers agree.
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        // `uuid` is a generated column, NULL for undo points; taskwarrior keeps synced operations.
        guard let counted = query(db, "SELECT count(DISTINCT uuid) FROM operations WHERE NOT synced", { Int(sqlite3_column_int64($0, 0)) }),
              let count = counted,
              let base = query(db, "SELECT value FROM sync_meta WHERE key = 'base_version'", { sqlite3_column_text($0, 0).map { String(cString: $0) } })
        else { return nil }
        return ReplicaState(baseVersion: base.flatMap { $0 } ?? nilVersion, unsyncedTasks: count)
    }

    /// The first row read by `column`, `.some(nil)` for no rows, or nil if the query failed.
    private static func query<T>(_ db: OpaquePointer, _ sql: String, _ column: (OpaquePointer) -> T) -> T?? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .some(column(statement))
        case SQLITE_DONE: return .some(nil)
        default: return nil
        }
    }
}
