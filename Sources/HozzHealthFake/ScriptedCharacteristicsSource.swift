import Foundation
import HozzCore

/// A ``HealthCharacteristicsSource`` with a fixed answer, so tests can assert
/// on how characteristics reach the export without a device that has any.
public actor ScriptedCharacteristicsSource: HealthCharacteristicsSource {
    private let scripted: HealthCharacteristics
    private var reads = 0

    public init(_ characteristics: HealthCharacteristics) {
        self.scripted = characteristics
    }

    public init(
        readAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        _ characteristics: [HealthCharacteristic]
    ) {
        self.scripted = HealthCharacteristics(
            readAt: readAt,
            characteristics: characteristics
        )
    }

    /// How many times the export asked. Used to check the record is written
    /// once per attempt rather than once per type.
    public var readCount: Int {
        reads
    }

    public func characteristics() async -> HealthCharacteristics {
        reads += 1
        return scripted
    }
}
