import XCTest
import HozzCore
@testable import HozzHealth

/// Sleep described twice must be counted once.
///
/// A watch and a phone both writing a night, or a third-party sleep app running
/// alongside the watch, produce records that cover the same minutes. Adding
/// their durations reports a night that never happened, and it errs generously —
/// so it reads as a good night's sleep rather than as an obvious fault.
final class ExportSleepUnionTests: XCTestCase {
    private func stretch(_ from: String, _ to: String) -> DateInterval {
        DateInterval(start: date(from), end: date(to))
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    /// Two sources describing one night report that night once.
    ///
    /// The expectation is arithmetic done here rather than by the code under
    /// test: 23:00 to 07:00 is eight hours, so the union is 28,800 seconds
    /// whatever the sources claim separately. Summing them would give 15 hours,
    /// which is both wrong and flattering.
    func testANightDescribedByTwoDevicesIsCountedOnce() {
        let watch = stretch("2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z")
        let phone = stretch("2026-03-01T23:30:00Z", "2026-03-02T06:30:00Z")

        let union = TimeUnion.seconds(of: [watch, phone])

        XCTAssertEqual(union, 8 * 3_600, accuracy: 0.5)
        XCTAssertEqual(
            watch.duration + phone.duration,
            15 * 3_600,
            accuracy: 0.5,
            "Adding them is what this exists to prevent; if that stops being 15 "
                + "hours the fixture has drifted and the test proves nothing."
        )
    }

    /// A stretch wholly inside another does not shorten the night.
    ///
    /// Taking the later end unconditionally would shrink the union to the
    /// contained record, reporting less sleep than either source claimed.
    func testAShortRecordInsideALongOneDoesNotShortenIt() {
        let night = stretch("2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z")
        let deep = stretch("2026-03-02T02:00:00Z", "2026-03-02T03:00:00Z")

        XCTAssertEqual(
            TimeUnion.seconds(of: [night, deep]),
            8 * 3_600,
            accuracy: 0.5
        )
    }

    /// Stretches that touch are one stretch.
    ///
    /// A record ending at 03:00 and another beginning at 03:00 describe
    /// continuous sleep. Counting them separately is harmless for a total but
    /// wrong for anything that asks how many stretches there were.
    func testTouchingStretchesBecomeOne() {
        let first = stretch("2026-03-01T23:00:00Z", "2026-03-02T03:00:00Z")
        let second = stretch("2026-03-02T03:00:00Z", "2026-03-02T07:00:00Z")

        let merged = TimeUnion.merge([first, second])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(TimeUnion.seconds(of: [first, second]), 8 * 3_600, accuracy: 0.5)
    }

    /// A genuine gap stays a gap.
    ///
    /// Waking for an hour in the middle of the night is not sleep, and a union
    /// that swallowed the gap would report more sleep than happened — the same
    /// error in the other direction.
    func testARealGapIsNotFilledIn() {
        let first = stretch("2026-03-01T23:00:00Z", "2026-03-02T02:00:00Z")
        let second = stretch("2026-03-02T03:00:00Z", "2026-03-02T07:00:00Z")

        let merged = TimeUnion.merge([first, second])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(TimeUnion.seconds(of: [first, second]), 7 * 3_600, accuracy: 0.5)
    }

    /// Order of arrival does not change the answer.
    ///
    /// Records reach the writer in whatever order the export produced them, and
    /// a union that depended on that order would give different totals for the
    /// same night on different runs.
    func testTheAnswerDoesNotDependOnTheOrderRecordsArrive() {
        let a = stretch("2026-03-02T02:00:00Z", "2026-03-02T07:00:00Z")
        let b = stretch("2026-03-01T23:00:00Z", "2026-03-02T03:00:00Z")
        let c = stretch("2026-03-02T06:00:00Z", "2026-03-02T06:30:00Z")

        XCTAssertEqual(
            TimeUnion.seconds(of: [a, b, c]),
            TimeUnion.seconds(of: [c, b, a]),
            accuracy: 0.5
        )
        XCTAssertEqual(TimeUnion.seconds(of: [a, b, c]), 8 * 3_600, accuracy: 0.5)
    }

    /// Nothing asleep is nought, not an error.
    func testNoSleepIsNoSeconds() {
        XCTAssertEqual(TimeUnion.seconds(of: []), 0)
        XCTAssertTrue(TimeUnion.merge([]).isEmpty)
    }

    /// A zero-length record contributes nothing rather than breaking the union.
    func testAZeroLengthRecordIsIgnored() {
        let empty = stretch("2026-03-02T03:00:00Z", "2026-03-02T03:00:00Z")
        let night = stretch("2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z")

        XCTAssertEqual(TimeUnion.seconds(of: [empty, night]), 8 * 3_600, accuracy: 0.5)
        XCTAssertEqual(TimeUnion.merge([empty]).count, 0)
    }

    /// The export's own summary counts an overlapping night once.
    ///
    /// This drives `DaySummary` rather than `TimeUnion` directly, because the
    /// bug was not in the union — there was no union. It was in the summary
    /// adding durations as records arrived.
    func testTheDaySummaryCountsAnOverlappingNightOnce() {
        var summary = ExportMarkdownWriter.DaySummary()
        let watch = sleepRecord(
            id: "watch",
            from: "2026-03-01T23:00:00Z",
            to: "2026-03-02T07:00:00Z"
        )
        let phone = sleepRecord(
            id: "phone",
            from: "2026-03-01T23:30:00Z",
            to: "2026-03-02T06:30:00Z"
        )

        summary.add(sleep: watch)
        summary.add(sleep: phone)

        XCTAssertEqual(summary.asleepSeconds, 8 * 3_600, accuracy: 0.5)
        XCTAssertEqual(
            summary.sleepSegments,
            2,
            "Both records still arrived; it is the minutes that must not double."
        )
    }

    /// An asleep record as the spool actually writes one.
    private func sleepRecord(id: String, from: String, to: String) -> ExportRecord {
        let object: [String: Any] = [
            "kind": "category",
            "id": id,
            "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "startDate": from,
            "endDate": to,
            "value": 1
        ]
        let line = try! JSONSerialization.data(withJSONObject: object)
        return ExportRecord(line: line)!
    }
}
