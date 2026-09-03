import Foundation
import HozzCatalog
import HozzCore

/// Turns read characteristics into the record that goes into an export.
///
/// The record is deliberately not shaped like a sample. Its canonical
/// identity names the characteristics snapshot rather than pretending
/// HealthKit supplied a sample UUID or measurement date.
enum HealthCharacteristicsRecord {
    static let kind = "characteristics"

    static func make(
        from characteristics: HealthCharacteristics,
        recordVersion: Int64
    ) -> [String: any Sendable] {
        var values: [String: any Sendable] = [:]
        for characteristic in characteristics.characteristics {
            values[characteristic.type.rawValue] = object(for: characteristic)
        }

        let sourceID = "characteristics"
        let sourceType = "HozzRecordType:characteristics"
        return [
            "kind": kind,
            "schemaVersion": HozzHealthArchiveContract.schemaVersion,
            "id": sourceID,
            "canonicalId": HozzHealthArchiveContract.canonicalID(for: sourceID),
            "canonicalType": HozzHealthArchiveContract.canonicalType(
                for: sourceType,
                kind: kind
            ),
            "recordVersion": recordVersion,
            "type": sourceType,
            "sourceRecord": [
                "store": HozzHealthArchiveContract.sourceStore,
                "id": sourceID,
                "type": sourceType
            ],
            "lineage": [
                [
                    "store": HozzHealthArchiveContract.sourceStore,
                    "recordId": sourceID
                ]
            ],
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
