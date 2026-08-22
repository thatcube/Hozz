import Foundation
import HozzCore
import HozzStore
import XCTest

/// Covers the move from the pre-App-Group location into the shared container.
///
/// Enabling App Groups changes where the store resolves to. Getting this wrong
/// does not fail loudly — the app just opens an empty database, drops every
/// configured destination, and re-exports the user's entire Health history to
/// every destination they own. So each branch is pinned here.
final class StoreMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(
        at directory: URL,
        databaseContents: String,
        walContents: String? = nil,
        spoolFile: String? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let database = StoreLocation.databaseURL(in: directory)
        try Data(databaseContents.utf8).write(to: database)
        if let walContents {
            try Data(walContents.utf8).write(
                to: URL(fileURLWithPath: database.path + "-wal")
            )
        }
        if let spoolFile {
            let spool = directory.appending(path: "Spool", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: spool,
                withIntermediateDirectories: true
            )
            try Data("part".utf8).write(to: spool.appending(path: spoolFile))
        }
    }

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func testAnExistingStoreIsMovedIntoTheSharedContainer() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "real-database")
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true
        )

        try StoreLocation.migrateStore(from: legacy, to: shared)

        let moved = StoreLocation.databaseURL(in: shared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(try contents(of: moved), "real-database")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: StoreLocation.databaseURL(in: legacy).path
            ),
            "The legacy database must not be left behind to be reopened later."
        )
    }

    /// The write-ahead log holds committed transactions not yet folded into the
    /// main file. Those are the newest cursor commits, so losing the log means
    /// silently replaying data that was already delivered.
    func testTheWriteAheadLogTravelsWithTheDatabase() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(
            at: legacy,
            databaseContents: "db",
            walContents: "recent-commits"
        )

        try StoreLocation.migrateStore(from: legacy, to: shared)

        let movedWAL = URL(
            fileURLWithPath: StoreLocation.databaseURL(in: shared).path + "-wal"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedWAL.path))
        XCTAssertEqual(try contents(of: movedWAL), "recent-commits")
    }

    /// Spooled parts are referenced by rows in the database, so a resumable
    /// export breaks if they do not move with it.
    func testSpooledPartsTravelWithTheDatabase() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "db", spoolFile: "0001.part")

        try StoreLocation.migrateStore(from: legacy, to: shared)

        let movedPart = shared.appending(path: "Spool/0001.part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedPart.path))
    }

    /// The reverse data loss. A database already in the shared container is the
    /// live one; replacing it with a stale legacy copy would throw away
    /// everything recorded since the migration first ran.
    func testAnExistingSharedStoreIsNeverOverwritten() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "stale")
        try makeStore(at: shared, databaseContents: "live")

        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertEqual(
            try contents(of: StoreLocation.databaseURL(in: shared)),
            "live",
            "A live shared store must win over a stale legacy one."
        )
    }

    /// The exact trap this migration has to survive.
    ///
    /// Enabling App Groups changes where the store resolves to, and *any*
    /// launch — including the widget's, which the user never sees — creates the
    /// schema in the new location. A "does a database exist" check would then
    /// treat that empty husk as the live store and strand the real one forever.
    func testAnEmptySharedStoreDoesNotBlockMigration() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "real-database")

        // A real, valid, but completely empty Hozz database, exactly as a
        // widget launch would leave behind.
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true
        )
        let husk = try HozzStore(directory: shared)
        _ = husk

        XCTAssertFalse(
            StoreLocation.carriesUserState(at: StoreLocation.databaseURL(in: shared)),
            "A schema-only database holds nothing the user would miss."
        )

        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertEqual(
            try contents(of: StoreLocation.databaseURL(in: shared)),
            "real-database",
            "The real store must replace an empty husk."
        )
    }

    /// The opposite direction: once real state exists in the shared container
    /// it must win, or the user loses everything recorded since migrating.
    func testASharedStoreWithRealStateIsNeverReplaced() async throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "stale")
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true
        )

        let live = try HozzStore(directory: shared)
        try await live.commit(
            [
                PendingAnchorCommit(
                    type: XCTUnwrap(HealthTypeKey(rawValue: "HKQuantityTypeIdentifierStepCount")),
                    baseAnchor: nil,
                    anchor: AnchorToken(data: Data("anchor".utf8)),
                    coverage: .anchorClosed,
                    addedRecordCount: 12,
                    addedObservedCount: 12,
                    anchorClosedAt: nil,
                    failureReason: nil
                )
            ],
            scope: .global
        )

        XCTAssertTrue(
            StoreLocation.carriesUserState(at: StoreLocation.databaseURL(in: shared)),
            "A cursor is exactly the state that must not be thrown away."
        )

        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertNotEqual(
            try? contents(of: StoreLocation.databaseURL(in: shared)),
            "stale",
            "A live shared store must survive."
        )
    }

    func testMigrationIsIdempotent() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "db", spoolFile: "0001.part")

        try StoreLocation.migrateStore(from: legacy, to: shared)
        try StoreLocation.migrateStore(from: legacy, to: shared)
        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertEqual(try contents(of: StoreLocation.databaseURL(in: shared)), "db")
    }

    func testNothingHappensWithoutALegacyDatabase() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )

        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: StoreLocation.databaseURL(in: shared).path
            )
        )
    }

    /// A fresh install has no legacy directory at all.
    func testAMissingLegacyDirectoryIsNotAnError() throws {
        let legacy = root.appending(path: "does-not-exist/Hozz")
        let shared = root.appending(path: "shared/Hozz")

        XCTAssertNoThrow(try StoreLocation.migrateStore(from: legacy, to: shared))
    }

    /// If the group container is unavailable both paths resolve to the same
    /// place, and moving a directory onto itself would destroy it.
    func testMigratingOntoItselfIsARefusal() throws {
        let directory = root.appending(path: "same/Hozz")
        try makeStore(at: directory, databaseContents: "db")

        try StoreLocation.migrateStore(from: directory, to: directory)

        XCTAssertEqual(
            try contents(of: StoreLocation.databaseURL(in: directory)),
            "db"
        )
    }

    /// Files the user might still need are not deleted just because the
    /// database moved.
    func testALegacyDirectoryWithOtherFilesIsKept() throws {
        let legacy = root.appending(path: "legacy/Hozz")
        let shared = root.appending(path: "shared/Hozz")
        try makeStore(at: legacy, databaseContents: "db")
        try Data("keep".utf8).write(to: legacy.appending(path: "notes.txt"))

        try StoreLocation.migrateStore(from: legacy, to: shared)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appending(path: "notes.txt").path
            )
        )
    }
}
