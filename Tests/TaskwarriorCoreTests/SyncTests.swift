import XCTest
import SQLite3
@testable import TaskwarriorCore

final class ReplicaReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// taskchampion's schema, as taskwarrior 3.5 writes it, in WAL mode. Closed before the
    /// reader runs, so its shared-memory file is gone, as after a `task` command.
    private func makeDatabase(_ statements: [String]) throws {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent(ReplicaReader.fileName).path
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            "PRAGMA journal_mode = WAL",
            """
            CREATE TABLE operations (id INTEGER PRIMARY KEY AUTOINCREMENT, data STRING, synced bool DEFAULT false, uuid GENERATED ALWAYS AS (
                coalesce(json_extract(data, '$.Update.uuid'), json_extract(data, '$.Create.uuid'), json_extract(data, '$.Delete.uuid'))) VIRTUAL)
            """,
            "CREATE TABLE sync_meta (key STRING PRIMARY KEY, value STRING)",
        ]
        for sql in schema + statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }

    private func operation(_ kind: String, _ uuid: String, synced: Bool) -> String {
        "INSERT INTO operations (data, synced) VALUES ('{\"\(kind)\":{\"uuid\":\"\(uuid)\"}}', \(synced ? 1 : 0))"
    }

    func testCountsTasksNotOperationsAndSkipsSynced() throws {
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        try makeDatabase([
            operation("Create", a, synced: true),
            operation("Update", a, synced: false),
            operation("Update", a, synced: false),
            operation("Create", b, synced: false),
            "INSERT INTO operations (data, synced) VALUES ('\"UndoPoint\"', 0)",
            "INSERT INTO sync_meta VALUES ('base_version', 'aaaaaaaa-0000-0000-0000-000000000001')",
        ])
        XCTAssertEqual(ReplicaReader.read(dataDirectory: directory.path),
                       ReplicaState(baseVersion: "aaaaaaaa-0000-0000-0000-000000000001", unsyncedTasks: 2))
    }

    func testLeavesNoWALFilesBehind() throws {
        try makeDatabase([])
        // The fixture's own connection may leave them (Apple's SQLite persists WAL by default).
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(ReplicaReader.fileName + suffix))
        }
        XCTAssertNotNil(ReplicaReader.read(dataDirectory: directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [ReplicaReader.fileName])
    }

    func testNeverSyncedReplicaHasTheNilVersion() throws {
        try makeDatabase([])
        XCTAssertEqual(ReplicaReader.read(dataDirectory: directory.path),
                       ReplicaState(baseVersion: "00000000-0000-0000-0000-000000000000", unsyncedTasks: 0))
    }

    func testMissingDatabaseOrUnexpectedSchemaReadsNothing() throws {
        XCTAssertNil(ReplicaReader.read(dataDirectory: directory.path))
        var db: OpaquePointer?
        sqlite3_open(directory.appendingPathComponent(ReplicaReader.fileName).path, &db)
        sqlite3_exec(db, "CREATE TABLE operations (id INTEGER, data STRING)", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertNil(ReplicaReader.read(dataDirectory: directory.path))
    }
}

final class SyncServerTests: XCTestCase {
    let client = "8a2b3c4d-0000-4000-8000-000000000001"

    func testRequestForTheChildOfTheBaseVersion() throws {
        let server = try XCTUnwrap(SyncServer(config: ["sync.server.url": "https://tw.example.com/", "sync.server.client_id": client]))
        let request = server.childVersionRequest(of: "aaaaaaaa-0000-0000-0000-000000000001")
        XCTAssertEqual(request.url?.absoluteString, "https://tw.example.com/v1/client/get-child-version/aaaaaaaa-0000-0000-0000-000000000001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Id"), client)
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testOnlyAServerBackendIsProbed() {
        XCTAssertNotNil(SyncServer(config: ["sync.server.origin": "http://localhost:8080", "sync.server.client_id": client]))
        XCTAssertNil(SyncServer(config: ["sync.server.url": "https://tw.example.com", "sync.server.client_id": "nope"]))
        XCTAssertNil(SyncServer(config: ["sync.gcp.bucket": "b", "sync.encryption_secret": "s"]))
        XCTAssertTrue(SyncServer.isConfigured(config: ["sync.gcp.bucket": "b"]))
        XCTAssertFalse(SyncServer.isConfigured(config: ["sync.encryption_secret": "s", "data.location": "~/.task"]))
    }

    func testStatusMapping() {
        XCTAssertEqual(SyncServer.serverAhead(status: 200), true)
        XCTAssertEqual(SyncServer.serverAhead(status: 404), false)
        XCTAssertNil(SyncServer.serverAhead(status: 410))
        XCTAssertNil(SyncServer.serverAhead(status: 500))
    }
}

final class SyncStateTests: XCTestCase {
    func testSymbols() {
        XCTAssertEqual(SyncState().symbol, "icloud")
        XCTAssertEqual(SyncState(unsyncedTasks: 0, serverAhead: false).symbol, "checkmark.icloud")
        // Not probed: no claim that the server is in step.
        XCTAssertEqual(SyncState(unsyncedTasks: 0).symbol, "icloud")
        XCTAssertEqual(SyncState(unsyncedTasks: 3, serverAhead: false).symbol, "icloud.and.arrow.up")
        XCTAssertEqual(SyncState(unsyncedTasks: 0, serverAhead: true).symbol, "icloud.and.arrow.down")
        XCTAssertEqual(SyncState(unsyncedTasks: 3, serverAhead: true).symbol, "arrow.triangle.2.circlepath.icloud")
        XCTAssertEqual(SyncState(unsyncedTasks: 3, serverAhead: true, lastSyncFailed: true).symbol, "exclamationmark.icloud")
    }

    func testDueAndSummary() {
        XCTAssertFalse(SyncState(unsyncedTasks: 0, serverAhead: false).isDue)
        XCTAssertTrue(SyncState(unsyncedTasks: 1).isDue)
        XCTAssertTrue(SyncState(lastSyncFailed: true).isDue)
        XCTAssertEqual(SyncState(unsyncedTasks: 1, serverAhead: true).summary,
                       "1 task with unsynced changes · the server has changes. Click to sync.")
    }
}
