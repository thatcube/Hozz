import Foundation
import HozzCore

/// One voltage reading from an electrocardiogram.
public struct ECGVoltage: Equatable, Sendable, SeriesElement {
    /// Where the reading sits in the recording, in seconds from its start.
    public let timeSinceStart: TimeInterval
    /// The reading itself, in volts. `nil` where the lead reported nothing,
    /// which is kept as a gap rather than filled in with a zero.
    public let volts: Double?
    /// The instant the reading was taken, derived from the recording's start.
    public let timestamp: Date

    public init(timeSinceStart: TimeInterval, volts: Double?, timestamp: Date) {
        self.timeSinceStart = timeSinceStart
        self.volts = volts
        self.timestamp = timestamp
    }

    public var seriesTimestamp: Date {
        timestamp
    }

    public var seriesObject: [String: any Sendable] {
        var object: [String: any Sendable] = [
            "timeSinceStart": timeSinceStart
        ]
        if let volts {
            object["volts"] = volts
        }
        return object
    }
}

/// What the Watch decided the recording showed.
///
/// The raw value is carried alongside the name so a classification from a
/// later OS is still readable, rather than becoming an unexplained gap.
public struct ECGClassification: Equatable, Sendable {
    public let name: String
    public let rawValue: Int

    public init(name: String, rawValue: Int) {
        self.name = name
        self.rawValue = rawValue
    }
}

public enum ElectrocardiogramEncoding {
    public static let typeIdentifier = "HKDataTypeIdentifierElectrocardiogram"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    public static let shape = SeriesShape(
        typeIdentifier: typeIdentifier,
        headerKind: "electrocardiogram",
        elementKind: "electrocardiogramVoltages",
        endKind: "electrocardiogramEnd",
        elementsKey: "voltages",
        // A recording is about 30 seconds at 512 Hz. At 500 readings per
        // record that is roughly 30 records, each a few kilobytes.
        elementsPerRecord: 500,
        recordsPerPage: 8
    )

    /// Adds the fields that make a recording readable on its own: what the
    /// Watch classified it as, how fast the heart was going, how the reading
    /// was sampled, and whether the person said they felt anything.
    ///
    /// Every one of these is optional in HealthKit, and an absent value is
    /// left out rather than written as a zero. An average heart rate of 0 is
    /// not a measurement.
    public static func basePayload(
        _ payload: Data,
        classification: ECGClassification,
        symptomsStatus: ECGClassification,
        averageHeartRate: Double?,
        samplingFrequencyHertz: Double?,
        numberOfVoltageMeasurements: Int
    ) throws -> Data {
        guard
            var object = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any]
        else {
            throw HealthSampleEncodingError.invalidJSONObject
        }

        object["classification"] = [
            "name": classification.name,
            "rawValue": classification.rawValue
        ]
        object["symptomsStatus"] = [
            "name": symptomsStatus.name,
            "rawValue": symptomsStatus.rawValue
        ]
        object["numberOfVoltageMeasurements"] = numberOfVoltageMeasurements
        if let averageHeartRate {
            object["averageHeartRate"] = [
                "unit": "count/min",
                "value": averageHeartRate
            ]
        }
        if let samplingFrequencyHertz {
            object["samplingFrequency"] = [
                "unit": "Hz",
                "value": samplingFrequencyHertz
            ]
        }
        return try SeriesEncoding.serialize(object)
    }
}
