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
        catalogEntry: HealthCatalogEntry,
        medications: [AnyHashable: MedicationConceptFacts] = [:]
    ) throws -> Data {
        var object = baseObject(sample: sample)

        // Handled ahead of the switch because `HKStateOfMind` only exists on
        // iOS 18, and a `case let x as HKStateOfMind` would not compile against
        // a deployment target that predates it.
        if #available(iOS 18.0, *), let stateOfMind = sample as? HKStateOfMind {
            object["kind"] = "stateOfMind"
            object.merge(StateOfMindEncoding.object(for: stateOfMind)) {
                current, _ in current
            }
            return try serialize(object)
        }

        // A clinical record does not go through the switch because its
        // identity is not its UUID, so it cannot share the base object's `id`.
        if let clinical = sample as? HKClinicalRecord {
            ClinicalRecordEncoding.decorate(
                &object,
                record: Self.facts(for: clinical)
            )
            return try serialize(object)
        }

        // Handled ahead of the switch for the same reason as State of Mind:
        // `HKMedicationDoseEvent` does not exist on this deployment target and
        // cannot appear in a case pattern.
        if #available(iOS 26.0, *), let dose = sample as? HKMedicationDoseEvent {
            object["kind"] = "medicationDose"
            object.merge(
                MedicationEncoding.object(
                    for: HealthKitMedicationDirectory.facts(for: dose),
                    medication: medications[
                        AnyHashable(dose.medicationConceptIdentifier)
                    ] ?? .unresolved(
                        reason: "Hozz could not find the medication this dose refers to."
                    )
                )
            ) { current, _ in current }
            return try serialize(object)
        }

        switch sample {
        case let quantity as HKQuantitySample:
            guard let unitString = catalogEntry.canonicalUnit else {
                throw HealthSampleEncodingError.missingCanonicalUnit(sample.sampleType.identifier)
            }
            let unit = HKUnit(from: unitString)
            object["kind"] = "quantity"
            object["quantity"] = Self.quantityObject(
                unit: unitString,
                value: quantity.quantity.doubleValue(for: unit),
                description: quantity.quantity.description,
                count: quantity.count
            )
        case let category as HKCategorySample:
            object["kind"] = "category"
            object["value"] = category.value
        case let workout as HKWorkout:
            object["kind"] = "workout"
            object["activityType"] = workout.workoutActivityType.rawValue
            object["duration"] = workout.duration
            WorkoutEncoding.decorate(
                &object,
                statistics: Self.statistics(from: workout.allStatistics),
                segments: workout.workoutActivities.map { activity in
                    WorkoutSegment(
                        id: activity.uuid,
                        activityType: activity.workoutConfiguration
                            .activityType.rawValue,
                        startDate: activity.startDate,
                        endDate: activity.endDate,
                        statistics: Self.statistics(from: activity.allStatistics)
                    )
                }
            )
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

        return try serialize(object)
    }

    private func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Reads a clinical record where HealthKit handed it over.
    static func facts(for record: HKClinicalRecord) -> ClinicalRecordFacts {
        var fhir: FHIRResourceFacts?
        if let resource = record.fhirResource {
            var version: String?
            if #available(iOS 14.0, *) {
                version = resource.fhirVersion.stringRepresentation
            }
            fhir = FHIRResourceFacts(
                resourceType: resource.resourceType.rawValue,
                identifier: resource.identifier,
                fhirVersion: version,
                sourceURL: resource.sourceURL,
                data: resource.data
            )
        }
        return ClinicalRecordFacts(
            healthKitID: record.uuid,
            clinicalType: record.clinicalType.identifier,
            displayName: record.displayName,
            sourceName: record.sourceRevision.source.name,
            sourceBundleIdentifier: record.sourceRevision.source
                .bundleIdentifier,
            startDate: record.startDate,
            endDate: record.endDate,
            fhir: fhir
        )
    }

    /// Turns Health's own workout aggregates into values.
    ///
    /// The unit comes from the catalogue, which is the same unit the type's
    /// individual samples are written in, so a workout's average heart rate
    /// and its heart rate samples can be compared without conversion. A type
    /// the catalogue has no unit for is skipped rather than guessed at.
    static func statistics(
        from all: [HKQuantityType: HKStatistics]
    ) -> [WorkoutStatistic] {
        all.compactMap { quantityType, statistics in
            guard
                let unitString = HealthTypeCatalog
                    .entriesByIdentifier[quantityType.identifier]?
                    .canonicalUnit
            else {
                return nil
            }
            let unit = HKUnit(from: unitString)
            return WorkoutStatistic(
                type: quantityType.identifier,
                unit: unitString,
                sum: statistics.sumQuantity()?.doubleValue(for: unit),
                average: statistics.averageQuantity()?.doubleValue(for: unit),
                minimum: statistics.minimumQuantity()?.doubleValue(for: unit),
                maximum: statistics.maximumQuantity()?.doubleValue(for: unit)
            )
        }
    }

    /// Shapes a quantity, saying plainly when the one number stands for many.
    ///
    /// HealthKit stores some readings — a workout's power or cadence, for
    /// instance — as a *series*: one sample whose `quantity` is an aggregate
    /// over `count` individual values that only `HKQuantitySeriesSampleQuery`
    /// can reach. Written without that count, an average of three hundred
    /// readings is indistinguishable from a single measurement, which is a
    /// quiet way of overstating what Hozz actually knows.
    ///
    /// Hozz does not expand those series yet, so the honest thing is to say
    /// the detail exists and is not here, rather than to let the aggregate
    /// pass for a reading.
    static func quantityObject(
        unit: String,
        value: Double,
        description: String,
        count: Int
    ) -> [String: Any] {
        var object: [String: Any] = [
            "unit": unit,
            "value": value,
            "description": description,
            "count": count
        ]
        if count > 1 {
            object["aggregatesSeries"] = true
        }
        return object
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
