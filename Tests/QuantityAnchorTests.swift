import HealthKit
import HozzCore
import XCTest
@testable import HozzHealth

/// The cursor every ordinary type shares.
///
/// This is the widest blast radius in Hozz: roughly a hundred and ninety
/// quantity and category types read through one anchor format, so a decoding
/// mistake here does not break one type's stream, it breaks all of them. The
/// tests that matter most are therefore the boring ones — that a cursor
/// written before any of this existed still reads, and still writes back
/// byte for byte as it was.
final class QuantityAnchorTests: XCTestCase {
    private let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    /// A cursor in the shape every device already has: the exact bytes
    /// `NSKeyedArchiver` produced for a real `HKQueryAnchor`, with nothing
    /// wrapped around them.
    private func legacyToken(value: Int = 42) throws -> AnchorToken {
        try HealthKitAnchorCoding.token(for: HKQueryAnchor(fromValue: value))
    }

    // MARK: - Nobody's cursor resets

    func testARealAnchorFromAnOlderBuildStillReads() throws {
        let token = try legacyToken()
        let decoded = try QuantityAnchor.decode(token)

        XCTAssertEqual(
            decoded.healthKitAnchor,
            token.data,
            "The stored bytes must come back untouched."
        )
        XCTAssertTrue(decoded.pendingSeries.isEmpty)
        XCTAssertEqual(decoded.deliveredReadings, 0)
    }

    func testARealAnchorFromAnOlderBuildStillUnarchivesAfterARoundTrip() throws {
        let original = HKQueryAnchor(fromValue: 4_711)
        let token = try HealthKitAnchorCoding.token(for: original)

        let rewritten = try QuantityAnchor.decode(token).token()
        XCTAssertEqual(
            rewritten,
            token,
            "A cursor with nothing pending must be written back exactly as it came."
        )
        XCTAssertEqual(
            try HealthKitAnchorCoding.anchor(for: rewritten),
            original,
            "And HealthKit must still accept it as its own anchor."
        )
    }

    func testAnEmptyQueueIsNeverWrittenAsTheCompositeShape() throws {
        let token = try legacyToken()
        let anchor = QuantityAnchor(healthKitAnchor: token.data)

        // Not merely equal to the legacy bytes — provably not JSON, so a build
        // that has never heard of series expansion can still read it.
        XCTAssertNil(
            try? JSONSerialization.jsonObject(with: try anchor.token().data),
            """
            A cursor with nothing pending must stay a bare HealthKit anchor. \
            Wrapping every type's cursor in a new format would make the \
            feature impossible to back out of.
            """
        )
    }

    func testAnAnchorThatFinishesItsQueueReturnsToTheLegacyShape() throws {
        let token = try legacyToken()
        let sample = UUID()
        let pending = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: [sample],
            deliveredReadings: 500
        )

        XCTAssertNotEqual(try pending.token(), token, "While work is pending.")
        XCTAssertEqual(
            try pending.advancedPastPendingSample().token(),
            token,
            "And back to the original bytes once it is done."
        )
    }

    // MARK: - The composite shape

    func testACursorWithWorkPendingSurvivesARoundTrip() throws {
        let token = try legacyToken()
        let first = UUID()
        let second = UUID()
        let anchor = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: [first, second],
            deliveredReadings: 1_500
        )

        let decoded = try QuantityAnchor.decode(anchor.token())
        XCTAssertEqual(decoded.healthKitAnchor, token.data)
        XCTAssertEqual(
            decoded.pendingSeries,
            [first, second],
            "Order is the queue. Losing it would expand samples twice."
        )
        XCTAssertEqual(decoded.deliveredReadings, 1_500)
    }

    func testTheStoredCursorStillCarriesUsableHealthKitBytes() throws {
        let original = HKQueryAnchor(fromValue: 99)
        let token = try HealthKitAnchorCoding.token(for: original)
        let anchor = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: [UUID()]
        )

        let decoded = try QuantityAnchor.decode(anchor.token())
        XCTAssertEqual(
            try HealthKitAnchorCoding.anchor(
                for: decoded.healthKitAnchor.map { AnchorToken(data: $0) }
            ),
            original,
            """
            The queue is Hozz's business; the bytes inside it are HealthKit's, \
            and they have to come back out of the composite intact.
            """
        )
    }

    func testTheStoredCursorHasAFixedByteLayout() throws {
        let anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [
                UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
            ],
            deliveredReadings: 7
        )

        // Written out rather than compared against a second call, which would
        // only prove the encoder agrees with itself within one launch. JSON
        // key order for a Swift dictionary is stable inside a process and
        // varies between them, so a run-twice test passes whether or not the
        // keys are sorted — and unsorted keys would make a cursor that had not
        // moved look, on every launch, as though it had.
        XCTAssertEqual(
            String(decoding: try anchor.token().data, as: UTF8.self),
            #"{"format":"hozzQuantityAnchor","hk":"Y3Vyc29y","offset":7,"series":["00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000002"],"v":1}"#
        )
    }

    func testTheSameCursorAlwaysEncodesToTheSameBytes() throws {
        let token = try legacyToken()
        let samples = [UUID(), UUID(), UUID()]
        let anchor = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: samples,
            deliveredReadings: 7
        )

        XCTAssertEqual(
            try anchor.token(),
            try anchor.token(),
            "A cursor that encoded differently each time would look like progress."
        )
    }

    // MARK: - Cursors that must be refused rather than guessed at

    func testACursorFromANewerBuildIsRefusedRatherThanMisread() throws {
        let object: [String: Any] = [
            "format": "hozzQuantityAnchor",
            "v": 2,
            "series": [UUID().uuidString],
            "offset": 0
        ]
        let token = AnchorToken(
            data: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertThrowsError(try QuantityAnchor.decode(token)) { error in
            XCTAssertEqual(
                error as? QuantityAnchorError,
                .unsupportedVersion(2),
                """
                Reading it as a HealthKit anchor would crash the unarchiver, \
                and starting over would re-export everything. Refusing keeps \
                the cursor exactly where it is.
                """
            )
        }
    }

    func testAQueueEntryThatWillNotParseIsRefusedRatherThanDropped() throws {
        let object: [String: Any] = [
            "format": "hozzQuantityAnchor",
            "v": 1,
            "hk": Data("cursor".utf8).base64EncodedString(),
            "series": [UUID().uuidString, "not-a-uuid"],
            "offset": 0
        ]
        let token = AnchorToken(
            data: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertThrowsError(try QuantityAnchor.decode(token)) { error in
            XCTAssertEqual(
                error as? QuantityAnchorError,
                .malformed,
                """
                HealthKit's anchor has already moved past a queued sample, so \
                dropping the entry would lose its readings for good.
                """
            )
        }
    }

    func testAnOffsetWithNoSampleIsRefused() throws {
        let object: [String: Any] = [
            "format": "hozzQuantityAnchor",
            "v": 1,
            "hk": Data("cursor".utf8).base64EncodedString(),
            "series": [],
            "offset": 500
        ]
        let token = AnchorToken(
            data: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertThrowsError(try QuantityAnchor.decode(token)) { error in
            XCTAssertEqual(error as? QuantityAnchorError, .malformed)
        }
    }

    func testANegativeOffsetIsRefused() throws {
        let object: [String: Any] = [
            "format": "hozzQuantityAnchor",
            "v": 1,
            "hk": Data("cursor".utf8).base64EncodedString(),
            "series": [UUID().uuidString],
            "offset": -1
        ]
        let token = AnchorToken(
            data: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertThrowsError(try QuantityAnchor.decode(token)) { error in
            XCTAssertEqual(error as? QuantityAnchorError, .malformed)
        }
    }

    func testAnUnrecognisedJSONObjectIsTreatedAsHealthKitBytesNotAsOurs() throws {
        // Something that parses as JSON but is not one of ours. It must not be
        // mistaken for a composite cursor and half-read.
        let token = AnchorToken(
            data: try JSONSerialization.data(
                withJSONObject: ["something": "else"]
            )
        )
        let decoded = try QuantityAnchor.decode(token)
        XCTAssertEqual(decoded.healthKitAnchor, token.data)
        XCTAssertTrue(decoded.pendingSeries.isEmpty)
    }

    /// Bytes that are neither a composite cursor nor valid JSON at all.
    ///
    /// These are the inputs most likely to arrive from a store that was
    /// written to while something was going wrong, and each one takes a
    /// different route through the guard: `jsonObject` throwing, or succeeding
    /// with something that is not a dictionary. Every one of them has to fall
    /// back to "these are HealthKit's bytes" rather than throw, because
    /// throwing on a legacy cursor would stall a type that was working.
    func testNothingThatIsNotOursIsEverRefused() throws {
        let inputs: [(String, Data)] = [
            ("empty", Data()),
            ("truncated archive", Data("bplist00\u{01}\u{02}".utf8)),
            ("a JSON array", try JSONSerialization.data(withJSONObject: [1, 2])),
            ("a bare number", Data("42".utf8)),
            ("a quoted string", Data("\"cursor\"".utf8)),
            ("random bytes", Data([0x00, 0xFF, 0x10, 0x7F]))
        ]

        for (name, data) in inputs {
            let token = AnchorToken(data: data)
            let decoded = try QuantityAnchor.decode(token)
            XCTAssertEqual(
                decoded.healthKitAnchor,
                data,
                "\(name) must be handed back as HealthKit's own bytes."
            )
            XCTAssertTrue(decoded.pendingSeries.isEmpty, name)
        }
    }

    func testACompositeWithNoHealthKitPositionIsRefused() throws {
        // Neither shape of this is writable: with a queue it would wedge the
        // type the moment the queue emptied, and without one it would read as
        // a fresh start and re-export the type's entire history.
        for series in [[UUID().uuidString], []] {
            let token = AnchorToken(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "format": "hozzQuantityAnchor",
                        "v": 1,
                        "series": series,
                        "offset": 0
                    ]
                )
            )
            XCTAssertThrowsError(try QuantityAnchor.decode(token)) { error in
                XCTAssertEqual(error as? QuantityAnchorError, .malformed)
            }
        }
    }

    func testACursorWithNoHealthKitPositionCannotBeWritten() {
        XCTAssertThrowsError(
            try QuantityAnchor(
                healthKitAnchor: nil,
                pendingSeries: [UUID()]
            ).token()
        ) { error in
            XCTAssertEqual(error as? QuantityAnchorError, .malformed)
        }
        XCTAssertThrowsError(try QuantityAnchor.start.token()) { error in
            XCTAssertEqual(error as? QuantityAnchorError, .malformed)
        }
    }

    /// Everything `decode` accepts, `token` can write back.
    ///
    /// The two drifting apart is how a cursor becomes unwritable: it reads
    /// fine, work is done against it, and then the result cannot be stored —
    /// which discards the work and does so again on every pass after.
    func testEveryCursorThatCanBeReadCanBeWrittenBackAndReadAgain() throws {
        let hk = try legacyToken().data
        let samples = [UUID(), UUID()]
        let cursors = [
            QuantityAnchor(healthKitAnchor: hk),
            QuantityAnchor(healthKitAnchor: hk, pendingSeries: [samples[0]]),
            QuantityAnchor(
                healthKitAnchor: hk,
                pendingSeries: samples,
                deliveredReadings: 1_000
            )
        ]

        for cursor in cursors {
            let once = try cursor.token()
            let read = try QuantityAnchor.decode(once)
            XCTAssertEqual(read.healthKitAnchor, cursor.healthKitAnchor)
            XCTAssertEqual(read.pendingSeries, cursor.pendingSeries)
            XCTAssertEqual(read.deliveredReadings, cursor.deliveredReadings)
            XCTAssertEqual(try read.token(), once, "And stable thereafter.")
        }
    }

    func testNoCursorAtAllIsTheStartRatherThanAFailure() throws {
        let decoded = try QuantityAnchor.decode(nil)
        XCTAssertNil(decoded.healthKitAnchor)
        XCTAssertTrue(decoded.pendingSeries.isEmpty)
        XCTAssertEqual(decoded.deliveredReadings, 0)
    }

    // MARK: - Moving through the queue

    func testAdvancingThroughTheQueueKeepsTheHealthKitBytesAndResetsTheOffset() throws {
        let token = try legacyToken()
        let first = UUID()
        let second = UUID()
        let anchor = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: [first, second],
            deliveredReadings: 900
        )

        let next = anchor.advancedPastPendingSample()
        XCTAssertEqual(next.pendingSeries, [second])
        XCTAssertEqual(
            next.deliveredReadings,
            0,
            "The next sample starts at its own beginning, not the last one's."
        )
        XCTAssertEqual(
            next.healthKitAnchor,
            token.data,
            "HealthKit's own position is unaffected by Hozz's queue."
        )
    }

    func testAdvancingWithinASampleChangesOnlyTheOffset() throws {
        let token = try legacyToken()
        let sample = UUID()
        let anchor = QuantityAnchor(
            healthKitAnchor: token.data,
            pendingSeries: [sample]
        )

        let next = anchor.advanced(toReading: 500)
        XCTAssertEqual(next.pendingSeries, [sample])
        XCTAssertEqual(next.deliveredReadings, 500)
        XCTAssertEqual(next.healthKitAnchor, token.data)
        XCTAssertNotEqual(
            try next.token(),
            try anchor.token(),
            """
            A page that wrote readings must leave a different cursor, or the \
            drain treats it as an anchor that refused to advance.
            """
        )
    }
}
