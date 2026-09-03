import Foundation
import HealthKit
import HozzCore
@testable import HozzHealth
import XCTest

/// A number that is not a number, in a sample's metadata.
///
/// JSON has no way to write NaN or an infinity, and `JSONSerialization` does
/// not fail politely for that one value — `isValidJSONObject` rejects the
/// **whole object**. So a single sample carrying a non-finite number could not
/// be encoded at all, and for a series type that is permanent: the reader
/// takes one sample per page, the encode throws, and the anchor never advances
/// past it. One awkward record stops a whole type for good.
///
/// Everything else in the metadata tagging was already safe — dates, data,
/// quantities, arrays, and a catch-all for anything unrecognised. The number
/// case handed the `NSNumber` straight through, which is right for every
/// finite value and fatal for three of them.
final class MetadataEncodingTests: XCTestCase {
    private let type = HKQuantityType(.stepCount)

    private func sample(metadata: [String: Any]) -> HKQuantitySample {
        HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: 12),
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_060),
            metadata: metadata
        )
    }

    private func metadata(of sample: HKSample) throws -> [String: Any] {
        let data = try HealthSampleEncoder().encodeBaseFields(sample: sample)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(object["metadata"] as? [String: Any])
    }

    func testBaseFieldsCarryCanonicalIdentityAndSourceLineage() throws {
        let sample = sample(metadata: [:])
        let data = try HealthSampleEncoder().encodeBaseFields(sample: sample)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let sourceID = sample.uuid.uuidString.lowercased()

        XCTAssertEqual(
            object["canonicalId"] as? String,
            "apple.healthkit:\(sourceID)"
        )
        XCTAssertEqual(object["canonicalType"] as? String, "activity.steps")
        XCTAssertEqual(object["recordVersion"] as? Int, 1)
        XCTAssertEqual(
            (object["sourceRecord"] as? [String: Any])?["id"] as? String,
            sourceID
        )
        XCTAssertEqual(
            (object["lineage"] as? [[String: Any]])?.first?["store"] as? String,
            "apple.healthkit"
        )
    }

    // MARK: - The three values that could not be written

    func testANonFiniteNumberDoesNotStopTheSampleBeingEncoded() throws {
        for (name, value) in [
            ("nan", Double.nan),
            ("infinity", Double.infinity),
            ("-infinity", -Double.infinity)
        ] {
            let encoded = try metadata(
                of: sample(metadata: ["HozzTestValue": NSNumber(value: value)])
            )
            let tagged = try XCTUnwrap(
                encoded["HozzTestValue"] as? [String: Any],
                name
            )
            XCTAssertEqual(tagged["type"] as? String, "nonFiniteNumber", name)
            XCTAssertEqual(tagged["value"] as? String, name)
        }
    }

    /// The expectation, arrived at without the function under test.
    func testTheThreeNamesAreTheThreeThingsTheyName() {
        XCTAssertEqual(HealthSampleEncoder.nonFiniteName(.nan), "nan")
        XCTAssertEqual(HealthSampleEncoder.nonFiniteName(0.0 / 0.0), "nan")
        XCTAssertEqual(HealthSampleEncoder.nonFiniteName(.infinity), "infinity")
        XCTAssertEqual(HealthSampleEncoder.nonFiniteName(1.0 / 0.0), "infinity")
        XCTAssertEqual(
            HealthSampleEncoder.nonFiniteName(-.infinity),
            "-infinity"
        )
        XCTAssertEqual(
            HealthSampleEncoder.nonFiniteName(-1.0 / 0.0),
            "-infinity"
        )
    }

    /// The failure this replaced: one bad value taking the whole record with
    /// it, not merely itself.
    func testOneBadValueNoLongerCostsEveryOtherFieldInTheRecord() throws {
        let encoded = try metadata(
            of: sample(
                metadata: [
                    "HozzTestValue": NSNumber(value: Double.nan),
                    HKMetadataKeyWasUserEntered: true,
                    "HozzTestCount": NSNumber(value: 7)
                ]
            )
        )
        XCTAssertEqual(encoded.count, 3, "nothing was dropped to save the rest")

        let entered = try XCTUnwrap(
            encoded[HKMetadataKeyWasUserEntered] as? [String: Any]
        )
        XCTAssertEqual(entered["type"] as? String, "bool")
        XCTAssertEqual(entered["value"] as? Bool, true)

        let count = try XCTUnwrap(encoded["HozzTestCount"] as? [String: Any])
        XCTAssertEqual(count["type"] as? String, "number")
        XCTAssertEqual((count["value"] as? NSNumber)?.intValue, 7)
    }

    // MARK: - Everything finite is untouched

    /// The fix must not change how an ordinary number is written. Every
    /// receiver in the field reads these, and a number that started arriving
    /// as a string would break them for the sake of three values.
    func testFiniteNumbersAreWrittenExactlyAsBefore() throws {
        let cases: [(String, NSNumber)] = [
            ("zero", NSNumber(value: 0)),
            ("integer", NSNumber(value: 42)),
            ("negative", NSNumber(value: -17)),
            ("fraction", NSNumber(value: 0.5)),
            ("verySmall", NSNumber(value: Double.leastNonzeroMagnitude)),
            ("veryLarge", NSNumber(value: Double.greatestFiniteMagnitude))
        ]
        var metadataIn: [String: Any] = [:]
        for (key, value) in cases {
            metadataIn[key] = value
        }
        let encoded = try metadata(of: sample(metadata: metadataIn))

        for (key, value) in cases {
            let tagged = try XCTUnwrap(encoded[key] as? [String: Any], key)
            XCTAssertEqual(tagged["type"] as? String, "number", key)
            XCTAssertEqual(
                (tagged["value"] as? NSNumber)?.doubleValue,
                value.doubleValue,
                key
            )
        }
    }

    /// A boolean is still a boolean. `NSNumber` wraps both, and the finiteness
    /// check sits after the boolean test for that reason.
    func testABooleanIsStillWrittenAsABoolean() throws {
        let encoded = try metadata(
            of: sample(metadata: [HKMetadataKeyWasUserEntered: false])
        )
        let tagged = try XCTUnwrap(
            encoded[HKMetadataKeyWasUserEntered] as? [String: Any]
        )
        XCTAssertEqual(tagged["type"] as? String, "bool")
        XCTAssertEqual(tagged["value"] as? Bool, false)
    }

    /// A non-finite number nested inside an array is the same hazard: the
    /// whole object is rejected, not just the element.
    ///
    /// Driven through the tagging directly, because HealthKit refuses an array
    /// as a metadata value at write time — so this branch cannot be reached
    /// through a real sample, which is exactly why it is worth checking.
    func testANonFiniteNumberInsideAnArrayIsAlsoHandled() throws {
        let tagged = try XCTUnwrap(
            HealthSampleEncoder().taggedMetadataValue(
                [NSNumber(value: 1), NSNumber(value: Double.infinity)]
            ) as? [String: Any]
        )
        XCTAssertEqual(tagged["type"] as? String, "array")

        let values = try XCTUnwrap(tagged["value"] as? [[String: Any]])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["type"] as? String, "number")
        XCTAssertEqual(values[1]["type"] as? String, "nonFiniteNumber")
        XCTAssertEqual(values[1]["value"] as? String, "infinity")
    }

    /// The property underneath all of it, asserted directly: whatever the
    /// tagging produces has to be something JSON can actually hold.
    func testAnythingTheTaggingProducesIsWritableAsJSON() throws {
        // Only value kinds HealthKit will actually store: it refuses an
        // array outright, so one here would be testing the fixture rather
        // than the encoder.
        let awkward: [String: Any] = [
            "nan": NSNumber(value: Double.nan),
            "posInf": NSNumber(value: Double.infinity),
            "negInf": NSNumber(value: -Double.infinity),
            "date": Date(timeIntervalSince1970: 1_700_000_000),
            "quantity": HKQuantity(unit: .count(), doubleValue: 3),
            "text": "ordinary",
            "flag": true,
            "number": NSNumber(value: 9)
        ]
        // Encoding at all is the assertion: `encodeBaseFields` throws
        // `invalidJSONObject` when the object cannot be written, which is
        // exactly the failure that stalled the stream.
        let encoded = try metadata(of: sample(metadata: awkward))
        XCTAssertEqual(encoded.count, awkward.count)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(encoded))
    }
}
