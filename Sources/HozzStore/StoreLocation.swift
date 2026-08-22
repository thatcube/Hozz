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

    /// The private, non-user-visible directory holding the store and its spool.
    public static func supportDirectory(
        in container: URL? = nil
    ) throws -> URL {
        let base: URL
        if let container {
            base = container
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw StoreLocationError.directoryUnavailable
            }
            base = applicationSupport
        }

        let directory = base.appending(path: "Hozz", directoryHint: .isDirectory)
        try prepareDirectory(directory)
        return directory
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
