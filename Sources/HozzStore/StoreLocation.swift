import Foundation

public enum StoreLocationError: Error, LocalizedError, Sendable {
    case directoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            "Hozz could not prepare its private storage directory."
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
            // Falling back keeps the app fully working if the group is
            // unavailable; only the widget loses its view of the state.
            let directory = try legacySupportDirectory()
            try prepareDirectory(directory)
            return directory
        }

        let directory = shared.appending(path: "Hozz", directoryHint: .isDirectory)
        try prepareDirectory(directory)
        // Enabling the App Groups capability changes where the store resolves
        // to, so an existing install must be carried across.
        if let legacy = try? legacySupportDirectory() {
            try migrateStore(from: legacy, to: directory)
        }
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

        // A database that exists but holds nothing is not worth preserving, and
        // the real store has to be moved out from under it.
        for stale in databaseFileURLs(for: databaseURL(in: directory)) {
            try? fileManager.removeItem(at: stale)
        }

        // The caller normally prepares this first, but a migration that only
        // works when someone else happened to create the directory is a trap.
        try prepareDirectory(directory)

        // The write-ahead log holds committed transactions that are not yet in
        // the main file, so moving the database without its side files would
        // lose the most recent work — exactly the cursors that matter most.
        for source in databaseFileURLs(for: legacyDatabase) {
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            let target = directory.appending(path: source.lastPathComponent)
            try fileManager.moveItem(at: source, to: target)
            try harden(target)
        }

        // Spooled parts are referenced by rows in the database that just moved,
        // so they have to travel with it or a resumable export breaks.
        let legacySpool = legacy.appending(path: "Spool", directoryHint: .isDirectory)
        let targetSpool = directory.appending(path: "Spool", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: legacySpool.path),
           !fileManager.fileExists(atPath: targetSpool.path) {
            try fileManager.moveItem(at: legacySpool, to: targetSpool)
            try harden(targetSpool)
        }

        // Leaving an empty husk behind would make a later run look migratable
        // again; anything still inside is left alone rather than deleted.
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacy.path),
           remaining.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
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
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
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

        try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )

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
