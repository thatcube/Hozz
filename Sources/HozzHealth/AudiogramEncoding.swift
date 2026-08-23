import Foundation
import HealthKit
import HozzCore

/// Encodes a hearing test.
///
/// An audiogram is not a series: its sensitivity points sit on the sample
/// itself, at most thirty of them, so it travels the ordinary anchored path
/// and only needs a shape of its own.
///
/// The shape keeps two things HealthKit is careful about and a flat reading
/// would throw away. An ear with no measurement is left out rather than
/// written as 0 dB, which would read as perfect hearing. And a reading Health
/// marks as clamped is reported with its bound, because a clamped 90 dBHL
/// means "at least 90", not "90".
public enum AudiogramEncoding {
    public static let typeIdentifier = "HKDataTypeIdentifierAudiogram"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    static let hertz = "Hz"
    static let hearingLevel = "dBHL"

    static func sensitivityPoints(
        _ sample: HKAudiogramSample
    ) -> [[String: Any]] {
        sample.sensitivityPoints.map(object(for:))
    }

    static func object(for point: HKAudiogramSensitivityPoint) -> [String: Any] {
        [
            "frequency": quantity(
                point.frequency,
                unit: HKUnit.hertz(),
                unitString: hertz
            ),
            "ears": ears(of: point)
        ]
    }

    private static func ears(
        of point: HKAudiogramSensitivityPoint
    ) -> [[String: Any]] {
        if #available(iOS 18.1, *) {
            return point.tests.map { test in
                var object: [String: Any] = [
                    "ear": name(for: test.side),
                    "sensitivity": quantity(
                        test.sensitivity,
                        unit: HKUnit.decibelHearingLevel(),
                        unitString: hearingLevel
                    ),
                    "conduction": name(for: test.type),
                    "masked": test.masked
                ]
                if let range = test.clampingRange {
                    // A clamped reading is a bound, not a measurement. Saying
                    // so is the difference between "90 dB" and "at least 90 dB".
                    var clamping: [String: Any] = [:]
                    if let lower = range.lowerBound {
                        clamping["lowerBound"] = quantity(
                            lower,
                            unit: HKUnit.decibelHearingLevel(),
                            unitString: hearingLevel
                        )
                    }
                    if let upper = range.upperBound {
                        clamping["upperBound"] = quantity(
                            upper,
                            unit: HKUnit.decibelHearingLevel(),
                            unitString: hearingLevel
                        )
                    }
                    if !clamping.isEmpty {
                        object["clampingRange"] = clamping
                    }
                }
                return object
            }
        }

        // Before iOS 18.1 a point carries only a left and a right reading,
        // with no conduction, masking, or clamping to report. Those fields are
        // left out rather than defaulted, so absent means unknown.
        var ears: [[String: Any]] = []
        if let left = point.leftEarSensitivity {
            ears.append([
                "ear": "left",
                "sensitivity": quantity(
                    left,
                    unit: HKUnit.decibelHearingLevel(),
                    unitString: hearingLevel
                )
            ])
        }
        if let right = point.rightEarSensitivity {
            ears.append([
                "ear": "right",
                "sensitivity": quantity(
                    right,
                    unit: HKUnit.decibelHearingLevel(),
                    unitString: hearingLevel
                )
            ])
        }
        return ears
    }

    @available(iOS 18.1, *)
    private static func name(for side: HKAudiogramSensitivityTestSide) -> String {
        switch side {
        case .left: "left"
        case .right: "right"
        @unknown default: "unrecognisedByHozz"
        }
    }

    @available(iOS 18.1, *)
    private static func name(for type: HKAudiogramConductionType) -> String {
        switch type {
        case .air: "air"
        @unknown default: "unrecognisedByHozz"
        }
    }

    private static func quantity(
        _ quantity: HKQuantity,
        unit: HKUnit,
        unitString: String
    ) -> [String: Any] {
        [
            "unit": unitString,
            "value": quantity.doubleValue(for: unit),
            "description": quantity.description
        ]
    }
}
