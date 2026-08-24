import Foundation
import HozzStore

/// What the archive is costing, in bytes someone can check against their disk.
///
/// Expanding quantity series multiplies what a receiver holds: a heart-rate
/// history that was a few thousand aggregate rows becomes those rows plus the
/// several hundred thousand readings behind them. That is the point of the
/// feature and it is what the user asked for, but it means the Mac can now grow
/// by hundreds of megabytes without anyone being told, and there is no
/// retention policy to stop it.
///
/// A number someone can look at is worth more than a clever policy they cannot
/// see. This is that number, broken down far enough to answer the only two
/// questions worth asking: how big is it, and what made it big.
public struct StorageReport: Hashable, Sendable {
    /// The database and its write-ahead log together, which is what the
    /// archive actually occupies. The log alone can be a large fraction of it
    /// after a big import, so reporting the main file alone would understate.
    public let databaseBytes: Int64
    /// Room left on the volume the archive sits on, as the system reports it
    /// for storage worth keeping. `nil` when the volume will not say.
    public let availableBytes: Int64?
    /// Below this, the receiver stops accepting batches rather than filling
    /// the disk.
    public let floorBytes: Int64

    public let sampleRows: Int
    public let quantitySeriesPageRows: Int
    /// Readings held across every expanded sample.
    public let quantitySeriesReadings: Int
    /// Bytes of reading data specifically, which is the part that grows.
    public let quantitySeriesBytes: Int64
    public let voltagePageRows: Int
    public let voltageBytes: Int64

    public init(
        databaseBytes: Int64,
        availableBytes: Int64?,
        floorBytes: Int64,
        sampleRows: Int,
        quantitySeriesPageRows: Int,
        quantitySeriesReadings: Int,
        quantitySeriesBytes: Int64,
        voltagePageRows: Int,
        voltageBytes: Int64
    ) {
        self.databaseBytes = databaseBytes
        self.availableBytes = availableBytes
        self.floorBytes = floorBytes
        self.sampleRows = sampleRows
        self.quantitySeriesPageRows = quantitySeriesPageRows
        self.quantitySeriesReadings = quantitySeriesReadings
        self.quantitySeriesBytes = quantitySeriesBytes
        self.voltagePageRows = voltagePageRows
        self.voltageBytes = voltageBytes
    }

    /// Whether there is room to accept more.
    ///
    /// A volume that will not report its free space is treated as having room.
    /// Refusing data because a question went unanswered would lose records to
    /// a missing answer rather than to a full disk.
    public var hasRoom: Bool {
        guard let availableBytes else {
            return true
        }
        return availableBytes >= floorBytes
    }
}

public enum IngestStorageError: Error, LocalizedError, Equatable, Sendable {
    case notEnoughRoom(availableBytes: Int64, floorBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .notEnoughRoom(let available, let floor):
            """
            This Mac has \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) \
            free, below the \(ByteCountFormatter.string(fromByteCount: floor, countStyle: .file)) \
            Hozz keeps in reserve, so the batch was refused rather than stored.
            """
        }
    }
}

extension IngestStore {
    /// Free space below which batches are refused.
    ///
    /// Chosen so a Mac that hits it still works: enough headroom for the
    /// system, and small enough that it only fires when the disk is genuinely
    /// nearly full rather than merely busy. The number matters less than that
    /// there is one — an archive with no floor at all fills the volume and
    /// takes the whole machine down with it, and the person finds out from
    /// something other than Hozz.
    public static let freeSpaceFloor: Int64 = 512 * 1_024 * 1_024

    /// How much room the archive is taking, and how much is left.
    public func storageReport() throws -> StorageReport {
        StorageReport(
            databaseBytes: databaseFileBytes(),
            availableBytes: availableBytes(),
            floorBytes: Self.freeSpaceFloor,
            sampleRows: count("SELECT COUNT(*) FROM sample"),
            quantitySeriesPageRows: count(
                "SELECT COUNT(*) FROM quantity_series_page"
            ),
            quantitySeriesReadings: count(
                "SELECT COALESCE(SUM(reading_count), 0) FROM quantity_series_page"
            ),
            quantitySeriesBytes: Int64(
                count(
                    "SELECT COALESCE(SUM(LENGTH(readings)), 0) FROM quantity_series_page"
                )
            ),
            voltagePageRows: count(
                "SELECT COUNT(*) FROM electrocardiogram_voltage_page"
            ),
            voltageBytes: Int64(
                count(
                    "SELECT COALESCE(SUM(LENGTH(points)), 0) FROM electrocardiogram_voltage_page"
                )
            )
        )
    }

    /// Refuses a batch when the disk is nearly full.
    ///
    /// Throwing rather than storing part of it is the whole point: the
    /// receiver answers with a failure, the phone keeps the batch and its
    /// cursor, and the data is still there once somebody makes room. Storing
    /// what fits and answering 200 would tell the phone it was delivered.
    func checkThereIsRoom() throws {
        guard let available = availableBytes() else {
            // The volume will not say. Refusing on a missing answer would lose
            // records to ignorance rather than to a full disk.
            return
        }
        guard available >= Self.freeSpaceFloor else {
            throw IngestStorageError.notEnoughRoom(
                availableBytes: available,
                floorBytes: Self.freeSpaceFloor
            )
        }
    }

    private func count(_ sql: String) -> Int {
        // A table that does not exist yet reports nothing rather than failing
        // a report someone asked for out of curiosity.
        Int((try? database.query(sql, row: { $0.integer(0) }))?.first ?? 0)
    }

    private func databaseFileBytes() -> Int64 {
        let base = storeDirectory.appending(path: "hozz-received.sqlite")
        // The write-ahead log and its index are part of what the archive
        // occupies, and after a large import the log is a real fraction of it.
        return ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let url = suffix.isEmpty
                ? base
                : URL(fileURLWithPath: base.path(percentEncoded: false) + suffix)
            let size = (try? FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false)
            )[.size]) as? NSNumber
            total += size?.int64Value ?? 0
        }
    }

    private func availableBytes() -> Int64? {
        try? storeDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }
}
