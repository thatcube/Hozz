import Foundation
import HozzCatalog
import HozzCore

/// Turns read characteristics into the record that goes into an export.
///
/// The record is deliberately not shaped like a sample. It has no `id`, no
/// `startDate`, and no source, because a characteristic has none of those
/// things, and giving it fake ones would make it look like a measurement taken
/// at export time.
enum HealthCharacteristicsRecord {
    static let kind = "characteristics"

    static func make(
        from characteristics: HealthCharacteristics
    ) -> [String: any Sendable] {
        var values: [String: any Sendable] = [:]
        for characteristic in characteristics.characteristics {
            values[characteristic.type.rawValue] = object(for: characteristic)
        }

        return [
            "kind": kind,
            "schemaVersion": 1,
            "catalogVersion": HealthTypeCatalog.version,
            "readAt": timestamp(characteristics.readAt),
            "characteristics": values
        ]
    }

    private static func object(
        for characteristic: HealthCharacteristic
    ) -> [String: any Sendable] {
        var object: [String: any Sendable] = [
            "state": characteristic.state.rawValue
        ]
        if let value = characteristic.value {
            object["value"] = value
        }
        if let rawValue = characteristic.rawValue {
            object["rawValue"] = rawValue
        }
        if let coverage = characteristic.coverage {
            object["coverage"] = coverage.rawValue
        }
        if let reason = characteristic.failureReason {
            object["reason"] = reason
        }
        return object
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
