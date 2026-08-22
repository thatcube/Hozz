import Foundation

public enum StoreLocationError: Error, LocalizedError, Sendable {
    case directoryUnavailable
    case storeMovedToAppGroup

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            "Hozz could not prepare its private storage directory."
        case .storeMovedToAppGroup:
            """
            Hozz's data has moved to its shared app group, which this build \
            cannot reach. Reinstall a build that has the App Groups capability \
            enabled; the data is still on the device.
            """
        }
    }
}

/// Resolves and hardens the on-disk locations Hozz uses for Health-derived
/// artifacts.
///
/// Every path produced here is protected and excluded from device backups.
/// Exclusion is applied to each item individually rather than relying on the
/// containing directory, because `isExcludedFromBackup` is a per-item resource
/// value and SQLite creates its `-wal` and `-shm` side files after the
/// directory has already been prepared.
public enum StoreLocation {
    /// Health-derived data is only readable while the device is unlocked, or by
    /// a file handle that was already open when the device locked. HealthKit
    /// itself refuses to read from a locked device, so a weaker protection
    /// class would widen exposure without enabling any additional work.
    public static let protection = FileProtectionType.completeUnlessOpen

    /// The app group both the app and its widget can reach.
    ///
    /// An app extension has its own data container, so without a shared group
    /// the widget would quietly create and read a second, empty database and
    /// permanently report that nothing had ever synced.
    public static let appGroupIdentifier = "group.com.thatcube.Hozz"

    /// The private, non-user-visible directory holding the store and its spool.
    public static func supportDirectory(
        in container: URL? = nil
    ) throws -> URL {
        if let container {
            let directory = container.appending(path: "Hozz", directoryHint: .isDirectory)
            try prepareDirectory(directory)
            return directory
        }

        guard let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return try legacyDirectory()
        }

        let directory = shared.appending(path: "Hozz", directoryHint: .isDirectory)
        do {
            try prepareDirectory(directory)
        } catch {
            // macOS hands back a group container path whether or not the app
            // is entitled to it, and the sandbox then denies the write. Refusing
            // to launch over that would be far worse than using the app's own
            // container, which is private but perfectly serviceable — only a
            // widget would notice the difference.
            return try legacyDirectory()
        }

        // Enabling the App Groups capability changes where the store resolves
        // to, so an existing install must be carried across.
        if let legacy = try? legacySupportDirectory() {
            try migrateStore(from: legacy, to: directory)
        }
        return directory
    }

    /// The app's own container, used when no group container is reachable.
    private static func legacyDirectory() throws -> URL {
        let directory = try legacySupportDirectory()
        // Once a migration has run, the store lives in the group container and
        // this directory is an empty shell. Creating a store here would not
        // "just lose the widget" — it would silently start over with no
        // destinations and no cursors, re-exporting the user's entire history.
        if hasMigrated(at: directory) {
            throw StoreLocationError.storeMovedToAppGroup
        }
        try prepareDirectory(directory)
        return directory
    }

    /// Where the store lived before the App Groups capability existed.
    public static func legacySupportDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreLocationError.directoryUnavailable
        }
        return applicationSupport.appending(path: "Hozz", directoryHint: .isDirectory)
    }

    /// Whether a database holds anything the user would notice losing.
    ///
    /// This exists because enabling App Groups can produce an empty database
    /// before the migration ever runs: any launch — including the widget's —
    /// resolves the new location and creates the schema there. A plain
    /// "does a file exist" check would then see that husk, conclude the shared
    /// store was already live, and strand the user's real store in the old
    /// location permanently.
    ///
    /// Destinations and cursors are the two things that cannot be recreated:
    /// losing destinations loses the user's configuration, and losing cursors
    /// re-exports their entire Health history to every destination.
    public static func carriesUserState(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        guard let database = try? SQLiteDatabase(url: url) else {
            // Unreadable is not the same as empty. Something is there, so it is
            // treated as live rather than risk deleting real data.
            return true
        }
        defer { database.close() }

        for table in ["destination", "stream_state"] {
            let counts = try? database.query(
                "SELECT COUNT(*) FROM \(table)",
                row: { $0.integer(0) }
            )
            guard let count = counts?.first else {
                // The table is missing, so this is not a store Hozz wrote in a
                // shape it understands. Leave it alone.
                return true
            }
            if count > 0 {
                return true
            }
        }
        return false
    }

    /// Moves a pre-App-Group store into the shared container.
    ///
    /// Without this, turning on App Groups silently points the app at a new,
    /// empty database. That is not a cosmetic reset: every destination the user
    /// configured disappears, and because cursors live in the same database,
    /// every type restarts from nothing and re-exports the user's entire Health
    /// history to every destination they own.
    ///
    /// The destination is never overwritten. If a database is already there it
    /// is the live one, and the legacy copy is stale — silently replacing it
    /// would be the same data loss in the opposite direction.
    ///
    /// The move is ordered so that a failure part-way through is always safe to
    /// retry. Everything that can fail happens *before* the database itself
    /// moves, which makes that single `moveItem` the commit point: either the
    /// database is still in the old location and the whole migration runs again
    /// next launch, or it is in the new one and the migration is complete.
    public static func migrateStore(from legacy: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        guard legacy.standardizedFileURL != directory.standardizedFileURL,
              fileManager.fileExists(atPath: legacy.path) else {
            return
        }

        let legacyDatabase = databaseURL(in: legacy)
        guard fileManager.fileExists(atPath: legacyDatabase.path) else {
            return
        }
        guard !carriesUserState(at: databaseURL(in: directory)) else {
            return
        }

        // Fold the write-ahead log into the database before anything moves.
        //
        // SQLite runs in WAL mode and iOS terminates apps without a clean
        // close, so the log routinely holds the newest committed cursors. If it
        // were moved as a separate file, any failure between the two moves
        // would strand it next to a database that had already moved — and the
        // "did the legacy database survive" check would report the migration as
        // done forever, silently discarding those cursors.
        guard checkpointWriteAheadLog(at: legacyDatabase) else {
            // Better to retry on the next launch than to move a database whose
            // most recent commits are still in a log.
            return
        }

        // A database that exists but holds nothing is not worth preserving, and
        // the real store has to be moved out from under it.
        for stale in databaseFileURLs(for: databaseURL(in: directory)) {
            try? fileManager.removeItem(at: stale)
        }

        // The caller normally prepares this first, but a migration that only
        // works when someone else happened to create the directory is a trap.
        try prepareDirectory(directory)

        // Spooled parts are referenced by rows in the database, so they move
        // first: if this fails the database has not moved yet and the whole
        // migration is retried, rather than leaving rows pointing at nothing.
        let legacySpool = legacy.appending(path: "Spool", directoryHint: .isDirectory)
        let targetSpool = directory.appending(path: "Spool", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: legacySpool.path),
           !fileManager.fileExists(atPath: targetSpool.path) {
            try fileManager.moveItem(at: legacySpool, to: targetSpool)
            try? harden(targetSpool)
        }

        // The commit point. After the checkpoint the side files hold nothing,
        // so this one file is the entire store.
        let target = databaseURL(in: directory)
        try fileManager.moveItem(at: legacyDatabase, to: target)

        // Everything from here is best-effort. A failed protection-class change
        // must not strand a store that has already moved successfully.
        try? harden(target)
        for leftover in databaseFileURLs(for: legacyDatabase) where leftover != legacyDatabase {
            try? fileManager.removeItem(at: leftover)
        }

        // A marker rather than deleting the directory: if a later build cannot
        // reach the group container, this is the only way to tell "the store
        // moved" apart from "this is a fresh install", and starting over would
        // wipe the user's configuration and cursors.
        try? Data(migrationMarkerContents.utf8).write(to: migrationMarker(in: legacy))
    }

    private static let migrationMarkerContents = "moved-to-app-group"

    static func migrationMarker(in directory: URL) -> URL {
        directory.appending(path: ".migrated-to-app-group")
    }

    /// Whether this location's store has already been moved into the group.
    public static func hasMigrated(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: migrationMarker(in: directory).path)
    }

    /// Folds the write-ahead log into the main database file.
    ///
    /// Returns whether the log is now empty, so a caller can decline to move a
    /// database whose newest commits still live somewhere else.
    static func checkpointWriteAheadLog(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        // A file that is not a SQLite database has no log to fold in, and
        // refusing to migrate it would strand it forever. Checked by header
        // rather than by trying to open it, because SQLite opens lazily and
        // only reports the problem later, which is indistinguishable from a
        // real checkpoint failure.
        guard isSQLiteDatabase(at: url) else {
            return true
        }
        guard let database = try? SQLiteDatabase(url: url) else {
            return false
        }
        defer { database.close() }
        do {
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            return true
        } catch {
            return false
        }
    }

    private static func isSQLiteDatabase(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    public static func databaseURL(in directory: URL) -> URL {
        directory.appending(path: "hozz.sqlite")
    }

    /// The SQLite database plus every side file SQLite may create beside it.
    public static func databaseFileURLs(for databaseURL: URL) -> [URL] {
        let path = databaseURL.path
        return [
            databaseURL,
            URL(fileURLWithPath: path + "-wal"),
            URL(fileURLWithPath: path + "-shm"),
            URL(fileURLWithPath: path + "-journal")
        ]
    }

    public static func spoolDirectory(in directory: URL) throws -> URL {
        let spool = directory.appending(path: "Spool", directoryHint: .isDirectory)
        try prepareDirectory(spool)
        return spool
    }

    public static func prepareDirectory(_ directory: URL) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        #else
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        #endif
        try harden(directory)
    }

    /// Applies the protection class and backup exclusion to an existing item.
    ///
    /// Missing items are ignored so callers can harden a set of paths that
    /// SQLite may not have created yet.
    public static func harden(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        // Per-file data protection is an iOS facility tied to the passcode.
        // macOS has no equivalent per-file class — whole-disk FileVault is the
        // real protection there — and asking for one throws, which would stop
        // the Mac app from creating its store at all.
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
        #endif

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    /// Reports whether an item is currently excluded from device backups.
    public static func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup ?? false
    }

    /// Reports the protection class currently applied to an item.
    public static func protectionType(
        of url: URL
    ) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[
            .protectionKey
        ] as? FileProtectionType
    }
}
