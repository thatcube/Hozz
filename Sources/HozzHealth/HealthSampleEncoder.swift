import CoreFoundation
import Foundation
import HealthKit
import HozzCatalog

public enum HealthSampleEncodingError: Error, Sendable {
    case invalidJSONObject
    case missingCanonicalUnit(String)
}

public struct HealthSampleEncoder: Sendable {
    public init() {}

    public func encode(
        sample: HKSample,
        catalogEntry: HealthCatalogEntry
    ) throws -> Data {
        var object = baseObject(sample: sample)

        switch sample {
        case let quantity as HKQuantitySample:
            guard let unitString = catalogEntry.canonicalUnit else {
                throw HealthSampleEncodingError.missingCanonicalUnit(sample.sampleType.identifier)
            }
            let unit = HKUnit(from: unitString)
            object["kind"] = "quantity"
            object["quantity"] = [
                "unit": unitString,
                "value": quantity.quantity.doubleValue(for: unit),
                "description": quantity.quantity.description
            ]
        case let category as HKCategorySample:
            object["kind"] = "category"
            object["value"] = category.value
        case let workout as HKWorkout:
            object["kind"] = "workout"
            object["activityType"] = workout.workoutActivityType.rawValue
            object["duration"] = workout.duration
            object["events"] = workout.workoutEvents?.map { event in
                [
                    "type": event.type.rawValue,
                    "startDate": Self.timestamp(event.dateInterval.start),
                    "endDate": Self.timestamp(event.dateInterval.end),
                    "metadata": metadataObject(event.metadata ?? [:])
                ] as [String: Any]
            } ?? []
        case let audiogram as HKAudiogramSample:
            object["kind"] = "audiogram"
            object["sensitivityPoints"] = AudiogramEncoding
                .sensitivityPoints(audiogram)
        case let correlation as HKCorrelation:
            object["kind"] = "correlation"
            object["members"] = correlation.objects.sorted {
                $0.uuid.uuidString < $1.uuid.uuidString
            }.map { member in
                [
                    "id": member.uuid.uuidString.lowercased(),
                    "type": member.sampleType.identifier
                ]
            }
        default:
            object["kind"] = "sample"
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public func encodeDeletion(id: UUID, typeIdentifier: String) throws -> Data {
        let object: [String: Any] = [
            "kind": "deletion",
            "id": id.uuidString.lowercased(),
            "type": typeIdentifier,
            "schemaVersion": 1
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Records a sample Hozz could not encode losslessly.
    ///
    /// The record is written into the export in the sample's place so the
    /// output never silently omits an object HealthKit returned.
    public func encodeEncodingFailure(
        id: UUID,
        typeIdentifier: String,
        message: String
    ) throws -> Data {
        let object: [String: Any] = [
            "kind": "sampleEncodingError",
            "id": id.uuidString.lowercased(),
            "type": typeIdentifier,
            "message": message,
            "schemaVersion": 1
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// The fields every sample carries, without the type-specific ones.
    ///
    /// Used where a record has to be finished later — a workout route needs
    /// queries of its own to find its workout — so the sample's own fields are
    /// captured on HealthKit's queue and completed afterwards.
    public func encodeBaseFields(sample: HKSample) throws -> Data {
        let object = baseObject(sample: sample)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func baseObject(sample: HKSample) -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": sample.uuid.uuidString.lowercased(),
            "type": sample.sampleType.identifier,
            "catalogVersion": HealthTypeCatalog.version,
            "startDate": Self.timestamp(sample.startDate),
            "endDate": Self.timestamp(sample.endDate),
            "metadata": metadataObject(sample.metadata ?? [:]),
            "source": sourceObject(sample.sourceRevision)
        ]

        if let device = sample.device {
            object["device"] = deviceObject(device)
        }
        return object
    }

    private func sourceObject(_ revision: HKSourceRevision) -> [String: Any] {
        var object: [String: Any] = [
            "name": revision.source.name,
            "bundleIdentifier": revision.source.bundleIdentifier
        ]
        if let version = revision.version {
            object["version"] = version
        }
        if let productType = revision.productType {
            object["productType"] = productType
        }
        let os = revision.operatingSystemVersion
        object["operatingSystem"] = [
            "major": os.majorVersion,
            "minor": os.minorVersion,
            "patch": os.patchVersion
        ]
        return object
    }

    private func deviceObject(_ device: HKDevice) -> [String: Any] {
        var object: [String: Any] = [:]
        object["name"] = device.name
        object["manufacturer"] = device.manufacturer
        object["model"] = device.model
        object["hardwareVersion"] = device.hardwareVersion
        object["firmwareVersion"] = device.firmwareVersion
        object["softwareVersion"] = device.softwareVersion
        object["localIdentifier"] = device.localIdentifier
        object["udiDeviceIdentifier"] = device.udiDeviceIdentifier
        return object.compactMapValues { $0 }
    }

    private func metadataObject(_ metadata: [String: Any]) -> [String: Any] {
        metadata.reduce(into: [:]) { result, pair in
            result[pair.key] = taggedMetadataValue(pair.value)
        }
    }

    private func taggedMetadataValue(_ value: Any) -> Any {
        switch value {
        case let value as Date:
            return ["type": "date", "value": Self.timestamp(value)]
        case let value as String:
            return ["type": "string", "value": value]
        case let value as Data:
            return ["type": "data", "value": value.base64EncodedString()]
        case let value as HKQuantity:
            return ["type": "quantity", "description": value.description]
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return ["type": "bool", "value": value.boolValue]
            }
            return ["type": "number", "value": value]
        case let values as [Any]:
            return [
                "type": "array",
                "value": values.map(taggedMetadataValue)
            ]
        default:
            return [
                "type": "unsupported",
                "class": String(describing: type(of: value))
            ]
        }
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
