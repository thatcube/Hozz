import HealthKit
import HozzCatalog
import HozzCore
import HozzDeliver
import XCTest
@testable import HozzHealth

/// A series that only exists in this file.
///
/// `HKQuantitySeriesSampleBuilder` needs a store Health will accept writes to,
/// so a sample with `count > 1` cannot be constructed in a unit test at all.
/// That is the whole reason ``QuantitySeriesBackend`` exists: the offset
/// arithmetic, the resume path, and the exactly-once accounting run in the code
/// path every cursor in Hozz depends on, and none of it would otherwise be
/// testable without a device that happens to have the right recordings on it.
private final class FakeQuantitySeriesBackend: QuantitySeriesBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSeries: [UUID: [QuantityReading]]
    private var storedFacts: [UUID: SeriesFacts]
    private let batchSize: Int
    /// Thrown once the readings below have been handed over, so a failure part
    /// way through a sample can be tested rather than assumed about.
    private let failure: (any Error)?
    /// Leaves the stream open after the readings run out, as a query that is
    /// still running does. The only thing that can end it then is the reader
    /// being cancelled.
    private let neverFinishes: Bool
    private var factsCalls = 0
    private var readingsCalls = 0
    private var readingsDelivered = 0

    init(
        series: [UUID: [QuantityReading]],
        facts: [UUID: SeriesFacts],
        batchSize: Int = 64,
        failure: (any Error)? = nil,
        neverFinishes: Bool = false
    ) {
        self.storedSeries = series
        self.storedFacts = facts
        self.batchSize = batchSize
        self.failure = failure
        self.neverFinishes = neverFinishes
    }

    var openedStreams: Int {
        lock.withLock { readingsCalls }
    }

    var factsLookups: Int {
        lock.withLock { factsCalls }
    }

    /// Readings actually pulled out of Health, including the ones re-read and
    /// thrown away when a sample is re-opened part-way through.
    var readingsRead: Int {
        lock.withLock { readingsDelivered }
    }

    /// Removes a sample, as Health would if the user deleted it between pages.
    func remove(_ sample: UUID) {
        lock.withLock {
            storedSeries[sample] = nil
            storedFacts[sample] = nil
        }
    }

    /// Shortens a sample, as Health would if it were rewritten between pages.
    func truncate(_ sample: UUID, to count: Int) {
        lock.withLock {
            storedSeries[sample] = Array((storedSeries[sample] ?? []).prefix(count))
        }
    }

    func facts(for sample: UUID, type: HealthTypeKey) async throws -> SeriesFacts? {
        lock.withLock {
            factsCalls += 1
            return storedFacts[sample]
        }
    }

    func readings(
        for sample: UUID,
        type: HealthTypeKey,
        unit: String
    ) -> AsyncThrowingStream<[QuantityReading], any Error> {
        let all = lock.withLock {
            readingsCalls += 1
            return storedSeries[sample] ?? []
        }

        let size = batchSize
        let failure = failure
        let neverFinishes = neverFinishes
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < all.count {
                let end = min(index + size, all.count)
                let batch = Array(all[index..<end])
                self.lock.withLock { self.readingsDelivered += batch.count }
                continuation.yield(batch)
                index = end
            }
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            if neverFinishes {
                // Left open on purpose. A real query that has not reached the
                // end of its sample behaves exactly like this, and the only
                // thing that ends the read is the reader being cancelled.
                return
            }
            continuation.finish()
        }
    }
}

final class QuantitySeriesTests: XCTestCase {
    private let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")
    private let unit = "count/min"
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// Readings written out as literals rather than generated, so an expected
    /// average is arithmetic anyone can check by hand rather than a second run
    /// of the code under test.
    private let literalValues: [Double] = [
        62, 64, 61, 70, 88, 91, 77, 72, 69, 65,
        63, 66, 74, 80, 85, 79, 71, 68, 67, 64
    ]

    private func readings(_ values: [Double]) -> [QuantityReading] {
        values.enumerated().map { index, value in
            QuantityReading(
                value: value,
                startDate: base.addingTimeInterval(Double(index)),
                endDate: base.addingTimeInterval(Double(index) + 1)
            )
        }
    }

    private func facts(for readings: [QuantityReading]) -> SeriesFacts {
        SeriesFacts(
            startDate: readings.first?.startDate ?? base,
            endDate: readings.last?.endDate ?? base
        )
    }

    private func makeBackend(
        _ sample: UUID,
        values: [Double],
        batchSize: Int = 64
    ) -> FakeQuantitySeriesBackend {
        let elements = readings(values)
        return FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)],
            batchSize: batchSize
        )
    }

    // MARK: - Reading the output

    private func object(_ change: HealthChange) throws -> [String: Any] {
        guard case .upsert(let upsert) = change else {
            XCTFail("A deletion where a record was expected.")
            return [:]
        }
        guard
            let object = try JSONSerialization.jsonObject(
                with: upsert.canonicalPayload
            ) as? [String: Any]
        else {
            XCTFail("A record that is not a JSON object.")
            return [:]
        }
        return object
    }

    /// Every reading in a run of pages, in the order the pages address them.
    ///
    /// Pages are sorted by their own recorded offset rather than by the order
    /// they arrived, so a run that emitted them out of order would be caught
    /// here rather than quietly reassembled.
    private func exportedReadings(
        _ changes: [HealthChange],
        startingAt firstOffset: Int = 0
    ) throws -> [[String: Any]] {
        var pages: [(offset: Int, readings: [[String: Any]])] = []
        for change in changes {
            let object = try object(change)
            guard
                object["kind"] as? String == QuantitySeriesEncoding.elementKind
            else {
                continue
            }
            guard
                let offset = object["offset"] as? Int,
                let readings = object[QuantitySeriesEncoding.elementsKey]
                    as? [[String: Any]]
            else {
                XCTFail("A reading page without an offset or readings.")
                continue
            }
            pages.append((offset, readings))
        }
        pages.sort { $0.offset < $1.offset }

        var expected = firstOffset
        for page in pages {
            XCTAssertEqual(
                page.offset,
                expected,
                "Offsets must be contiguous, or readings fall through the gap."
            )
            expected += page.readings.count
        }
        return pages.flatMap(\.readings)
    }

    private func endMarker(_ changes: [HealthChange]) throws -> [String: Any]? {
        for change in changes {
            let object = try object(change)
            if object["kind"] as? String == QuantitySeriesEncoding.endKind {
                return object
            }
        }
        return nil
    }

    private func timestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }
        return try? Date(
            string,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    /// Runs a whole sample to completion, one page at a time, exactly as the
    /// drain would — including re-encoding the cursor between pages.
    private func drainToCompletion(
        sample: UUID,
        backend: any QuantitySeriesBackend,
        recordLimit: Int,
        expander: QuantitySeriesExpander? = nil,
        freshExpanderEachPage: Bool = false
    ) async throws -> (changes: [HealthChange], anchor: QuantityAnchor, pages: Int) {
        let healthKitAnchor = Data("cursor".utf8)
        var anchor = QuantityAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingSeries: [sample]
        )
        var reader = expander ?? QuantitySeriesExpander(backend: backend)
        var all: [HealthChange] = []
        var pages = 0

        while anchor.pendingSample != nil {
            if freshExpanderEachPage {
                reader = QuantitySeriesExpander(backend: backend)
            }
            let expansion = try await reader.expand(
                from: anchor,
                type: heartRate,
                unit: unit,
                recordLimit: recordLimit
            )
            XCTAssertFalse(
                expansion.changes.isEmpty,
                """
                A page with a sample still pending must write something. An \
                empty page is how the drain is told a type is caught up, and \
                it would stop with readings still owed.
                """
            )
            all.append(contentsOf: expansion.changes)
            pages += 1

            // Round-tripped through the stored shape, so the cursor under test
            // is the one that would actually survive a relaunch.
            anchor = try QuantityAnchor.decode(expansion.anchor.token())
            XCTAssertLessThan(pages, 200, "Runaway paging.")
        }
        return (all, anchor, pages)
    }

    // MARK: - Accuracy

    func testExpandedReadingsAverageBackToTheAggregateHealthReported() async throws {
        let sample = UUID()
        let backend = makeBackend(sample, values: literalValues)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )
        let exported = try exportedReadings(run.changes)

        // Computed here from the literals, by hand arithmetic, so this is not
        // the implementation agreeing with itself.
        let expectedAverage = literalValues.reduce(0, +)
            / Double(literalValues.count)
        let actualValues = exported.compactMap { $0["value"] as? Double }

        XCTAssertEqual(actualValues.count, literalValues.count)
        let actualAverage = actualValues.reduce(0, +) / Double(actualValues.count)
        XCTAssertEqual(
            actualAverage,
            expectedAverage,
            accuracy: 0.000_001,
            """
            The readings must average back to what a discrete quantity \
            sample's aggregate reports, or the export contradicts itself.
            """
        )

        // And against the aggregate as the export actually writes it, through
        // the encoder that writes it — so the two halves of the record are
        // checked against each other rather than each against the fixture.
        let aggregate = HealthSampleEncoder.quantityObject(
            unit: unit,
            value: expectedAverage,
            description: "\(expectedAverage) count/min",
            count: literalValues.count
        )
        XCTAssertEqual(
            actualAverage,
            aggregate["value"] as? Double ?? .nan,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            actualValues.count,
            aggregate["count"] as? Int,
            "As many readings exported as the aggregate says it stands for."
        )
        XCTAssertEqual(
            aggregate["unit"] as? String,
            unit,
            "And in the unit the reading pages are written in."
        )
        XCTAssertEqual(aggregate["aggregatesSeries"] as? Bool, true)
    }

    func testExpandedReadingsSumBackToACumulativeAggregate() async throws {
        let sample = UUID()
        // A cumulative type: the parent's quantity is the sum of its readings.
        let values: [Double] = [12, 30, 8, 44, 19, 7, 51, 26]
        let backend = makeBackend(sample, values: values)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )
        let exported = try exportedReadings(run.changes)

        let expectedSum: Double = 12 + 30 + 8 + 44 + 19 + 7 + 51 + 26
        XCTAssertEqual(expectedSum, 197, "The literal sum, written out.")

        let actualSum = exported
            .compactMap { $0["value"] as? Double }
            .reduce(0, +)
        XCTAssertEqual(actualSum, expectedSum, accuracy: 0.000_001)
    }

    func testEveryExportedValueIsTheValueHealthGaveInTheOrderItGaveIt() async throws {
        let sample = UUID()
        let backend = makeBackend(sample, values: literalValues, batchSize: 7)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )
        let exported = try exportedReadings(run.changes)

        XCTAssertEqual(
            exported.compactMap { $0["value"] as? Double },
            literalValues,
            "Value for value, in order. Not a sum that happens to match."
        )
    }

    func testEveryReadingTimestampFallsInsideTheParentSampleRange() async throws {
        let sample = UUID()
        // The parent's range is written out independently of the readings, as
        // HealthKit reports it: a series sample spans the whole recording, so
        // its bounds are wider than the first and last reading rather than
        // equal to them. Deriving them from the readings would make this test
        // true by construction and prove nothing.
        let parent = SeriesFacts(
            startDate: base.addingTimeInterval(-30),
            endDate: base.addingTimeInterval(120)
        )
        let elements = readings(literalValues)
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: parent]
        )

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )
        let exported = try exportedReadings(run.changes)
        XCTAssertEqual(exported.count, literalValues.count)

        for reading in exported {
            guard
                let start = timestamp(reading["startDate"]),
                let end = timestamp(reading["endDate"])
            else {
                XCTFail("A reading without a readable date range.")
                continue
            }
            XCTAssertGreaterThanOrEqual(start, parent.startDate)
            XCTAssertLessThanOrEqual(end, parent.endDate)
            XCTAssertLessThanOrEqual(start, end, "A range that runs backwards.")
        }

        // The end marker stands for the sample, so it carries the sample's own
        // range rather than the span of whichever readings happened to be in
        // the last page.
        let end = try endMarker(run.changes)
        XCTAssertEqual(timestamp(end?["startDate"]), parent.startDate)
        XCTAssertEqual(timestamp(end?["endDate"]), parent.endDate)
    }

    func testAReadingPageCarriesTheSameUnitTheAggregateIsWrittenIn() async throws {
        let sample = UUID()
        let backend = makeBackend(sample, values: literalValues)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )

        var pages = 0
        for change in run.changes {
            let object = try object(change)
            guard
                object["kind"] as? String == QuantitySeriesEncoding.elementKind
            else {
                continue
            }
            pages += 1
            XCTAssertEqual(
                object["unit"] as? String,
                unit,
                """
                A reading page must name the unit its values are in, and it \
                must be the unit the parent aggregate uses, or the two cannot \
                be compared without a conversion nobody knows to make.
                """
            )
            XCTAssertEqual(object["type"] as? String, heartRate.rawValue)
            XCTAssertEqual(
                object["sample"] as? String,
                sample.uuidString.lowercased(),
                "A reading page must name the aggregate it belongs to."
            )
        }
        XCTAssertGreaterThan(pages, 0)
    }

    func testTheCountsReconcile() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double(60 + $0 % 40) }
        let backend = makeBackend(sample, values: values)

        // One record per page, so this crosses page boundaries repeatedly.
        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 1
        )
        let exported = try exportedReadings(run.changes)

        XCTAssertEqual(
            exported.count,
            values.count,
            "Every reading exactly once: never zero times, never twice."
        )

        let end = try endMarker(run.changes)
        XCTAssertEqual(
            end?[QuantitySeriesEncoding.elementsKey] as? Int,
            values.count,
            "The end marker must agree with what was actually written."
        )

        // Independently: the page `count` fields must add up to the same total.
        var counted = 0
        for change in run.changes {
            let object = try object(change)
            if object["kind"] as? String == QuantitySeriesEncoding.elementKind {
                counted += object["count"] as? Int ?? -1
            }
        }
        XCTAssertEqual(counted, values.count)
    }

    func testASampleStandingForOneReadingIsNotASeries() {
        XCTAssertFalse(
            QuantitySeriesEncoding.isExpandable(count: 1, canonicalUnit: unit),
            """
            An ordinary measurement expanded as a series would write the same \
            number twice under two identifiers.
            """
        )
        XCTAssertFalse(
            QuantitySeriesEncoding.isExpandable(count: 0, canonicalUnit: unit)
        )
        XCTAssertTrue(
            QuantitySeriesEncoding.isExpandable(count: 2, canonicalUnit: unit)
        )
        XCTAssertFalse(
            QuantitySeriesEncoding.isExpandable(count: 300, canonicalUnit: nil),
            "Readings with no unit to convert into cannot be written."
        )
    }

    // MARK: - Paging, interruption, replay

    func testALongSeriesIsWrittenAcrossPagesWithoutGapsOrRepeats() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 1
        )
        XCTAssertEqual(run.pages, 3, "500, 500, then 200 and the end marker.")

        let exported = try exportedReadings(run.changes)
        XCTAssertEqual(exported.compactMap { $0["value"] as? Double }, values)
        XCTAssertNil(run.anchor.pendingSample, "The queue must empty.")
    }

    func testAnInterruptedSeriesResumesWhereItStoppedRatherThanRestarting() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        // A fresh expander for every page is exactly what a relaunch gives:
        // no live stream, only the cursor that survived.
        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 1,
            freshExpanderEachPage: true
        )

        let exported = try exportedReadings(run.changes)
        XCTAssertEqual(
            exported.compactMap { $0["value"] as? Double },
            values,
            """
            Resuming must neither restart the sample nor skip past the point \
            it stopped at.
            """
        )
        XCTAssertGreaterThan(
            backend.openedStreams,
            1,
            "Each relaunch has to re-open the sample; that is the path tested."
        )
    }

    func testTheOrdinaryPathReadsEachReadingOnceRatherThanRewindingPerPage() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        _ = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 1
        )

        XCTAssertEqual(
            backend.openedStreams,
            1,
            """
            Held open across pages. Re-opening every page would re-read the \
            whole sample each time and turn a long series quadratic.
            """
        )
        XCTAssertEqual(backend.readingsRead, values.count)
    }

    func testAReplayedPageIsByteIdentical() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let backend = makeBackend(sample, values: values)
        let anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [sample],
            deliveredReadings: 500
        )

        // The same cursor twice: a delivery that failed and was retried from
        // the anchor that was never committed.
        let first = try await QuantitySeriesExpander(backend: backend).expand(
            from: anchor,
            type: heartRate,
            unit: unit,
            recordLimit: 1
        )
        let second = try await QuantitySeriesExpander(backend: backend).expand(
            from: anchor,
            type: heartRate,
            unit: unit,
            recordLimit: 1
        )

        XCTAssertFalse(first.changes.isEmpty)
        XCTAssertEqual(
            first.changes,
            second.changes,
            """
            Identical identifiers and identical bytes, or a receiver stores a \
            replay as a second copy of readings it already holds.
            """
        )
        XCTAssertEqual(
            try first.anchor.token(),
            try second.anchor.token(),
            "And it must leave the cursor in the same place."
        )
    }

    func testAPageAddressesReadingsByAbsoluteOffsetNotByHowFarItGot() async throws {
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        // One page taken mid-sample, from a cursor that says 500 are durable.
        let expansion = try await QuantitySeriesExpander(backend: backend)
            .expand(
                from: QuantityAnchor(
                    healthKitAnchor: Data("cursor".utf8),
                    pendingSeries: [sample],
                    deliveredReadings: 500
                ),
                type: heartRate,
                unit: unit,
                recordLimit: 1
            )

        let object = try object(expansion.changes[0])
        XCTAssertEqual(object["offset"] as? Int, 500)
        XCTAssertEqual(
            object["sequence"] as? Int,
            1,
            "Sequence is derived from the offset, not from the page number."
        )
        let first = (object[QuantitySeriesEncoding.elementsKey]
            as? [[String: Any]])?.first
        XCTAssertEqual(
            first?["value"] as? Double,
            500,
            "The 501st reading, because 500 were already durable."
        )
    }

    func testAPageStaysInsideTheRecordBudgetItWasGiven() async throws {
        let sample = UUID()
        let values = (0..<10_000).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        for limit in [1, 3, 8, 500] {
            let expansion = try await QuantitySeriesExpander(backend: backend)
                .expand(
                    from: QuantityAnchor(
                        healthKitAnchor: Data("cursor".utf8),
                        pendingSeries: [sample]
                    ),
                    type: heartRate,
                    unit: unit,
                    recordLimit: limit
                )
            XCTAssertLessThanOrEqual(
                expansion.changes.count,
                min(limit, QuantitySeriesEncoding.recordsPerPage) + 1,
                """
                A page may take its budget in reading records plus, at most, \
                the end marker — never a whole ten-thousand-reading sample.
                """
            )
            XCTAssertEqual(
                expansion.changes.count,
                min(limit, QuantitySeriesEncoding.recordsPerPage),
                """
                And it must actually take it. There are ten thousand readings \
                waiting, so a page that returned fewer would be pacing the \
                drain far slower than it was told it could go.
                """
            )
        }
    }

    // MARK: - Draining a cursor written by another build

    /// A queue in a stored cursor is always emptied, whatever this build
    /// would have chosen to put there.
    ///
    /// Expansion is unconditional now, but the property that matters is not
    /// "the switch is gone" — it is that draining a queue is never conditional
    /// on anything. A cursor carrying work has to empty, or the aggregate's
    /// promise of `count` readings is never answered and the cursor never
    /// returns to its ordinary shape.
    func testACursorArrivingWithWorkQueuedIsAlwaysDrained() async throws {
        let sample = UUID()
        let elements = readings(literalValues)
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)]
        )
        let source = HealthKitHealthDataSource(quantitySeriesBackend: backend)
        let cursor = try QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [sample]
        ).token()

        let batch = try await source.changes(
            for: heartRate,
            after: cursor,
            limit: 8
        )

        XCTAssertEqual(
            try exportedReadings(batch.changes).compactMap {
                $0["value"] as? Double
            },
            literalValues
        )
        XCTAssertTrue(
            try QuantityAnchor.decode(batch.proposedAnchor).pendingSeries
                .isEmpty,
            "And the cursor returns to its ordinary shape rather than sticking."
        )
    }

    /// Pending readings are written before any new page is asked for.
    ///
    /// HealthKit's anchor has already moved past a queued sample, and there is
    /// no predicate that could find it again, so anything that ran the
    /// ordinary query first would lose those readings for good.
    func testPendingReadingsComeBeforeAnyNewPage() async throws {
        let sample = UUID()
        let elements = readings(literalValues)
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)]
        )
        // No HealthKit store is touched at all on this path, which is the
        // point: a cursor with work pending never reaches the anchored query.
        let source = HealthKitHealthDataSource(quantitySeriesBackend: backend)
        let cursor = try QuantityAnchor(
            healthKitAnchor: Data("not a real HealthKit anchor".utf8),
            pendingSeries: [sample]
        ).token()

        let batch = try await source.changes(
            for: heartRate,
            after: cursor,
            limit: 8
        )
        XCTAssertFalse(batch.changes.isEmpty)
        XCTAssertNotEqual(
            batch.proposedAnchor,
            cursor,
            "A page that wrote records must move the cursor."
        )
        for change in batch.changes {
            XCTAssertEqual(
                change.type,
                heartRate,
                "Every record in a page belongs to the type that was asked for."
            )
        }
    }

    func testASampleThatCannotBeReadIsCountedAsAnEncodingFailure() async throws {
        let sample = UUID()
        let backend = FakeQuantitySeriesBackend(series: [:], facts: [:])
        let source = HealthKitHealthDataSource(quantitySeriesBackend: backend)

        _ = try await source.changes(
            for: heartRate,
            after: try QuantityAnchor(
                healthKitAnchor: Data("cursor".utf8),
                pendingSeries: [sample]
            ).token(),
            limit: 8
        )

        let count = await source.encodingErrorCount(for: heartRate)
        XCTAssertEqual(
            count,
            1,
            """
            The run's manifest reports how many objects could not be encoded. \
            Leaving these out would understate what the export says about \
            itself.
            """
        )
    }

    // MARK: - Samples that change underneath the cursor

    func testASampleDeletedMidExpansionIsRecordedRatherThanLeftUnexplained() async throws {
        let sample = UUID()
        let backend = makeBackend(sample, values: literalValues)
        var anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [sample],
            deliveredReadings: 5
        )
        backend.remove(sample)

        let expansion = try await QuantitySeriesExpander(backend: backend)
            .expand(from: anchor, type: heartRate, unit: unit, recordLimit: 8)
        anchor = expansion.anchor

        XCTAssertEqual(expansion.changes.count, 1)
        let object = try object(expansion.changes[0])
        XCTAssertEqual(object["kind"] as? String, "sampleEncodingError")
        XCTAssertNil(
            anchor.pendingSample,
            "The queue must move on, or the cursor never advances again."
        )

        guard case .upsert(let upsert) = expansion.changes[0] else {
            return XCTFail("Expected a record.")
        }
        XCTAssertNotEqual(
            upsert.id,
            sample,
            """
            The sample's own identifier belongs to its aggregate record. \
            Writing the failure under it would replace a reading Hozz has \
            with a note about one it does not.
            """
        )
        XCTAssertEqual(
            upsert.id,
            HealthSampleEncoder.encodingFailureID(
                sourceRecordID: sample,
                typeIdentifier: heartRate.rawValue
            )
        )
        XCTAssertEqual(
            object["canonicalId"] as? String,
            "apple.healthkit:\(upsert.id.uuidString.lowercased())"
        )
        XCTAssertEqual(
            object["parentCanonicalId"] as? String,
            "apple.healthkit:\(sample.uuidString.lowercased())"
        )
        XCTAssertEqual(object["recordVersion"] as? Int, 3)
        XCTAssertEqual(
            object["resolutionCanonicalId"] as? String,
            SeriesEncoding.completionCanonicalID(
                shape: QuantitySeriesEncoding.shape(
                    for: heartRate.rawValue
                ),
                sample: sample
            )
        )
    }

    func testASampleThatShrankUnderTheCursorIsNotWrittenUnderStaleOffsets() async throws {
        let sample = UUID()
        let backend = makeBackend(sample, values: literalValues)
        // The cursor says twelve readings are durable; only four remain.
        backend.truncate(sample, to: 4)

        let expansion = try await QuantitySeriesExpander(backend: backend)
            .expand(
                from: QuantityAnchor(
                    healthKitAnchor: Data("cursor".utf8),
                    pendingSeries: [sample],
                    deliveredReadings: 12
                ),
                type: heartRate,
                unit: unit,
                recordLimit: 8
            )

        let object = try object(expansion.changes[0])
        XCTAssertEqual(
            object["kind"] as? String,
            "sampleEncodingError",
            """
            Continuing would write the remaining readings under offsets that \
            no longer mean what they meant when they were recorded.
            """
        )
        XCTAssertNil(expansion.anchor.pendingSample)
    }

    func testASeriesThatEnumeratesNothingIsAFailedReadNotAnEmptySeries() async throws {
        let sample = UUID()
        let backend = FakeQuantitySeriesBackend(
            series: [sample: []],
            facts: [sample: SeriesFacts(startDate: base, endDate: base)]
        )

        let expansion = try await QuantitySeriesExpander(backend: backend)
            .expand(
                from: QuantityAnchor(
                    healthKitAnchor: Data("cursor".utf8),
                    pendingSeries: [sample]
                ),
                type: heartRate,
                unit: unit,
                recordLimit: 8
            )

        XCTAssertNil(
            try endMarker(expansion.changes),
            """
            Nothing reaches the queue that does not claim at least two \
            readings, so an end marker saying nought would tell a receiver \
            this sample is complete and has no detail behind it — and nothing \
            would ever look at it again.
            """
        )
        XCTAssertEqual(expansion.changes.count, 1)
        XCTAssertEqual(
            try object(expansion.changes[0])["kind"] as? String,
            "sampleEncodingError"
        )
        XCTAssertNil(
            expansion.anchor.pendingSample,
            """
            It still moves on: a sample that cannot be read would otherwise \
            block every later sample of its type for good.
            """
        )
    }

    func testAnEmptyLastPageStillSealsASampleThatWasFullyWritten() async throws {
        let sample = UUID()
        // Exactly one full record's worth, so the page that writes it cannot
        // also discover the stream has ended.
        let values = (0..<500).map { Double($0) }
        let backend = makeBackend(sample, values: values)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 1
        )

        XCTAssertEqual(
            try endMarker(run.changes)?[QuantitySeriesEncoding.elementsKey]
                as? Int,
            500,
            """
            A page that finds the stream already spent must still seal the \
            sample, or a fully written series never gets its end marker.
            """
        )
        XCTAssertEqual(try exportedReadings(run.changes).count, 500)
    }

    func testSeveralQueuedSamplesAreExpandedOneAtATimeInOrder() async throws {
        let first = UUID()
        let second = UUID()
        let firstValues: [Double] = [10, 11, 12]
        let secondValues: [Double] = [20, 21]
        let firstReadings = readings(firstValues)
        let secondReadings = readings(secondValues)
        let backend = FakeQuantitySeriesBackend(
            series: [first: firstReadings, second: secondReadings],
            facts: [
                first: facts(for: firstReadings),
                second: facts(for: secondReadings)
            ]
        )

        let expander = QuantitySeriesExpander(backend: backend)
        var anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [first, second]
        )
        var all: [HealthChange] = []
        var guardrail = 0
        while anchor.pendingSample != nil, guardrail < 20 {
            let expansion = try await expander.expand(
                from: anchor,
                type: heartRate,
                unit: unit,
                recordLimit: 8
            )
            all.append(contentsOf: expansion.changes)
            anchor = try QuantityAnchor.decode(expansion.anchor.token())
            guardrail += 1
        }

        XCTAssertNil(anchor.pendingSample)
        var bySample: [String: [Double]] = [:]
        for change in all {
            let object = try object(change)
            guard
                object["kind"] as? String == QuantitySeriesEncoding.elementKind,
                let owner = object["sample"] as? String,
                let readings = object[QuantitySeriesEncoding.elementsKey]
                    as? [[String: Any]]
            else {
                continue
            }
            bySample[owner, default: []]
                .append(contentsOf: readings.compactMap { $0["value"] as? Double })
        }
        XCTAssertEqual(bySample[first.uuidString.lowercased()], firstValues)
        XCTAssertEqual(bySample[second.uuidString.lowercased()], secondValues)
    }

    // MARK: - Interruption that is not the end of the sample

    /// The bug this test exists for: a cancelled read looks exactly like a
    /// finished one.
    ///
    /// `AsyncThrowingStream` answers a cancelled read by ending the stream
    /// rather than by throwing, so a reader that treats "no more batches" as
    /// "the sample is over" will seal a half-read series with an end marker,
    /// drop it from the queue, and move HealthKit's anchor past it — and there
    /// is no predicate that can ever find that sample again. The background
    /// scheduler cancels *on purpose* when iOS takes its time back, so this is
    /// the ordinary checkpoint, not a rare accident.
    func testACancelledReadLeavesTheCursorAloneRatherThanSealingTheSample() async throws {
        let sample = UUID()
        let elements = readings((0..<300).map { Double($0) })
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)],
            // Fewer readings than a full record, and the query never ends, so
            // the reader is left waiting exactly as it would mid-sample.
            neverFinishes: true
        )
        let expander = QuantitySeriesExpander(backend: backend)
        let anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [sample]
        )
        // Bound locally so the task captures values rather than the test case.
        let type = heartRate
        let unitString = unit

        let task = Task {
            try await expander.expand(
                from: anchor,
                type: type,
                unit: unitString,
                recordLimit: 8
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            let expansion = try await task.value
            XCTFail(
                """
                Cancellation was read as the end of the sample. The page \
                returned \(expansion.changes.count) records and left the \
                cursor at \(expansion.anchor.pendingSeries.count) pending \
                samples; every reading after \
                \(expansion.anchor.deliveredReadings) is now unreachable.
                """
            )
        } catch is CancellationError {
            // Correct: nothing is written, so the caller commits nothing and
            // the sample is still named by the cursor it started from.
        }
    }

    func testAStreamThatFailsMidSampleLeavesTheCursorWhereItWas() async throws {
        struct Boom: Error {}
        let sample = UUID()
        let elements = readings((0..<300).map { Double($0) })
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)],
            failure: Boom()
        )

        do {
            _ = try await QuantitySeriesExpander(backend: backend).expand(
                from: QuantityAnchor(
                    healthKitAnchor: Data("cursor".utf8),
                    pendingSeries: [sample]
                ),
                type: heartRate,
                unit: unit,
                recordLimit: 8
            )
            XCTFail("A failed read must not be reported as a finished sample.")
        } catch is Boom {
            // Correct.
        }
    }

    /// The reason the live stream is forgotten before a page is built.
    ///
    /// The stream is held by reference, so reading from it during a page that
    /// then fails advances the reader the cursor still points at. If it were
    /// kept, the next page would carry on from where the *failed* page got to
    /// while labelling those readings with the offset the cursor recorded —
    /// writing readings under offsets that name different readings.
    func testAFailedPageDoesNotLeaveAStreamThatWouldSkipReadings() async throws {
        struct Boom: Error {}
        let sample = UUID()
        let values = (0..<1_200).map { Double($0) }
        let elements = readings(values)
        let expander = QuantitySeriesExpander(
            backend: FakeQuantitySeriesBackend(
                series: [sample: elements],
                facts: [sample: facts(for: elements)],
                failure: Boom()
            )
        )
        let anchor = QuantityAnchor(
            healthKitAnchor: Data("cursor".utf8),
            pendingSeries: [sample]
        )

        // One page succeeds, taking readings 0..<500 and leaving the rest
        // buffered; the next fails once the buffered readings run out.
        let first = try await expander.expand(
            from: anchor,
            type: heartRate,
            unit: unit,
            recordLimit: 1
        )
        let afterFirst = first.anchor
        do {
            _ = try await expander.expand(
                from: afterFirst,
                type: heartRate,
                unit: unit,
                recordLimit: 8
            )
            XCTFail("Expected the injected failure.")
        } catch is Boom {}

        // Retried from the cursor the failed page started at, against a
        // backend that now works. It must produce readings 500 onwards.
        let healthy = QuantitySeriesExpander(
            backend: FakeQuantitySeriesBackend(
                series: [sample: elements],
                facts: [sample: facts(for: elements)]
            )
        )
        let retry = try await healthy.expand(
            from: afterFirst,
            type: heartRate,
            unit: unit,
            recordLimit: 1
        )
        let exported = try exportedReadings(retry.changes, startingAt: 500)
        XCTAssertEqual(
            exported.first?["value"] as? Double,
            500,
            "The retry must resume at the first reading that is not durable."
        )
    }

    /// One expander serves roughly a hundred and ninety types.
    ///
    /// The cached stream is keyed by type as well as by sample and offset. If
    /// it were not, two types whose cursors happened to sit at the same offset
    /// would share a stream, and one type's readings would be exported under
    /// the other's identifiers.
    func testAStreamIsNeverReusedAcrossTypes() async throws {
        let sample = UUID()
        let cyclingPower = HealthTypeKey("HKQuantityTypeIdentifierCyclingPower")
        let values = (0..<1_200).map { Double(60 + $0 % 40) }
        let elements = readings(values)
        // Deliberately one sample identifier answering for both types, which
        // is the collision a type-blind cache would fall into: same sample,
        // same offset, different type.
        let backend = FakeQuantitySeriesBackend(
            series: [sample: elements],
            facts: [sample: facts(for: elements)]
        )
        let expander = QuantitySeriesExpander(backend: backend)

        // Heart rate takes a page and leaves the stream cached at offset 500.
        let heart = try await expander.expand(
            from: QuantityAnchor(
                healthKitAnchor: Data("cursor".utf8),
                pendingSeries: [sample]
            ),
            type: heartRate,
            unit: unit,
            recordLimit: 1
        )
        XCTAssertEqual(heart.anchor.deliveredReadings, 500)
        let openedForHeartRate = backend.openedStreams

        // A different type, same sample, same offset.
        let power = try await expander.expand(
            from: heart.anchor,
            type: cyclingPower,
            unit: "W",
            recordLimit: 1
        )
        XCTAssertGreaterThan(
            backend.openedStreams,
            openedForHeartRate,
            """
            The cached stream belongs to a different type. Continuing it would \
            export one type's readings under another type's identifiers.
            """
        )
        XCTAssertEqual(
            try object(power.changes[0])["type"] as? String,
            cyclingPower.rawValue
        )
        XCTAssertEqual(
            try object(power.changes[0])["unit"] as? String,
            "W",
            "And in its own unit, not the one the cached stream was read in."
        )
        XCTAssertEqual(
            try exportedReadings(power.changes, startingAt: 500)
                .first?["value"] as? Double,
            values[500],
            "Re-opened from the backend, so it starts at the recorded offset."
        )
    }

    // MARK: - Not adding a number to the numbers it is the average of

    /// The aggregate has to say its readings are here too.
    ///
    /// `aggregatesSeries` says "there is more detail than this number". It
    /// does not say "and it is in this export, keyed to this record's id",
    /// which is the fact that stops a consumer adding an hour of heart rate to
    /// itself — once as an average, once as three hundred readings.
    func testAnExpandedAggregateSaysItsReadingsAreAlsoHere() {
        let expanded = HealthSampleEncoder.quantityObject(
            unit: unit,
            value: 72.4,
            description: "72.4 count/min",
            count: 300
        )
        XCTAssertEqual(expanded["aggregatesSeries"] as? Bool, true)
        XCTAssertEqual(
            expanded["seriesReadingsExported"] as? Bool,
            true,
            "The mark that means: do not add this to its own children."
        )

        // An ordinary measurement has no children at all, so it must carry
        // neither mark — a consumer that skipped it would drop a real reading.
        let single = HealthSampleEncoder.quantityObject(
            unit: unit,
            value: 72,
            description: "72 count/min",
            count: 1
        )
        XCTAssertNil(single["aggregatesSeries"])
        XCTAssertNil(single["seriesReadingsExported"])
    }

    /// The promise is withdrawn by the one reader that cannot keep it.
    ///
    /// The anchored sweep notices a series sample as it goes past and queues
    /// its readings, so its records may say the readings travelled with them.
    /// A dated read cannot: paging readings needs a position inside the sample,
    /// and a date range has nowhere to carry one. Left saying otherwise, a
    /// consumer that excludes an aggregate because its readings are supposedly
    /// present would drop the sample outright — and go on dropping it until the
    /// sweep arrived, which is the weeks-long wait the dated read exists to
    /// avoid.
    func testADatedReadDoesNotPromiseReadingsItCannotSend() {
        let primed = HealthSampleEncoder.quantityObject(
            unit: unit,
            value: 72.4,
            description: "72.4 count/min",
            count: 300,
            expandsSeries: false
        )

        XCTAssertEqual(
            primed["aggregatesSeries"] as? Bool,
            true,
            """
            There is still more detail behind this number, and saying so is \
            what stops an average of three hundred readings being read as one \
            measurement.
            """
        )
        XCTAssertNil(
            primed["seriesReadingsExported"],
            "A promise about the rest of the export that nothing will keep."
        )
    }

    func testEverySeriesFamilysDetailIsRecognisedAsDetail() {
        for kind in [
            QuantitySeriesEncoding.elementKind,
            QuantitySeriesEncoding.endKind,
            WorkoutRouteEncoding.shape.elementKind,
            WorkoutRouteEncoding.shape.endKind,
            ElectrocardiogramEncoding.shape.elementKind,
            ElectrocardiogramEncoding.shape.endKind
        ] {
            XCTAssertTrue(SeriesEncoding.isDetailKind(kind), kind)
        }
        for kind in ["quantity", "category", "workout", "deletion", "audiogram"] {
            XCTAssertFalse(SeriesEncoding.isDetailKind(kind), kind)
        }
    }

    /// A reading page must not be filed inside a real metric.
    ///
    /// The metrics and InfluxDB shapes reduce a record to one number, and a
    /// page of five hundred readings is not one number. Sent anyway, it landed
    /// under "heart rate" as an extra point with no quantity, dated to the page
    /// rather than the reading, with a unit of "count" — so anything counting
    /// points per metric counted pages as readings.
    func testMetricsAndInfluxDestinationsAreNotGivenSeriesPages() throws {
        let sample = UUID()
        let shape = QuantitySeriesEncoding.shape(for: heartRate.rawValue)
        let aggregate = HealthChange.upsert(
            CapturedHealthObject(
                id: sample,
                type: heartRate,
                canonicalPayload: try SeriesEncoding.serialize([
                    "kind": "quantity",
                    "id": sample.uuidString.lowercased(),
                    "type": heartRate.rawValue,
                    "startDate": SeriesEncoding.timestamp(base),
                    "endDate": SeriesEncoding.timestamp(base),
                    "quantity": HealthSampleEncoder.quantityObject(
                        unit: unit,
                        value: 72.4,
                        description: "72.4 count/min",
                        count: 3
                    )
                ])
            )
        )
        let page = try SeriesEncoding.elementsChange(
            shape: shape,
            sample: sample,
            offset: 0,
            elements: readings([70, 72, 75]),
            sampleStart: base,
            sampleEnd: base.addingTimeInterval(3),
            extra: ["unit": unit]
        )
        let end = try SeriesEncoding.endChange(
            shape: shape,
            sample: sample,
            elementCount: 3,
            sampleStart: base,
            sampleEnd: base.addingTimeInterval(3)
        )
        let records = [aggregate, page, end]

        for format in [DeliveryFormat.metrics, .influx] {
            let payload = try DeliveryPayloadBuilder.build(
                records: records,
                destination: Destination(
                    name: "Test",
                    kind: .restAPI,
                    format: format,
                    endpointURL: URL(string: "https://example.invalid")
                )
            )
            let text = String(decoding: payload, as: UTF8.self)
            XCTAssertFalse(
                text.contains(QuantitySeriesEncoding.elementKind),
                "\(format) must not carry reading pages."
            )
            XCTAssertFalse(
                text.contains(
                    SeriesEncoding.identifier(
                        shape: shape,
                        sample: sample,
                        suffix: "\(QuantitySeriesEncoding.elementsKey)-0"
                    ).uuidString.lowercased()
                ),
                "\(format) must not carry a reading page under any name."
            )
            XCTAssertTrue(
                text.contains("72.4"),
                "\(format) must still carry the aggregate, exactly as before."
            )
        }
    }

    /// The lossless formats carry everything, which is the other half of the
    /// same decision: nothing is dropped, it is only kept out of the shapes
    /// that cannot represent it.
    func testTheLosslessFormatsStillCarryEveryReading() throws {
        let sample = UUID()
        let page = try SeriesEncoding.elementsChange(
            shape: QuantitySeriesEncoding.shape(for: heartRate.rawValue),
            sample: sample,
            offset: 0,
            elements: readings([70, 72, 75]),
            sampleStart: base,
            sampleEnd: base.addingTimeInterval(3),
            extra: ["unit": unit]
        )

        let payload = try DeliveryPayloadBuilder.build(
            records: [page],
            destination: Destination(
                name: "Test",
                kind: .folder,
                format: .ndjson,
                folderBookmark: Data("bookmark".utf8)
            )
        )
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(text.contains(QuantitySeriesEncoding.elementKind))
        for value in ["70", "72", "75"] {
            XCTAssertTrue(text.contains(value))
        }
    }

    // MARK: - The shared encoding stays as it was

    func testAddingPageFieldsDidNotChangeWhatRoutesAndRecordingsWrite() throws {
        let sample = UUID()
        let change = try SeriesEncoding.elementsChange(
            shape: ElectrocardiogramEncoding.shape,
            sample: sample,
            offset: 0,
            elements: [
                ECGVoltage(timeSinceStart: 0, volts: 0.001, timestamp: base)
            ],
            sampleStart: base,
            sampleEnd: base.addingTimeInterval(30)
        )
        let object = try object(change)
        let legacyFields: Set<String> = [
            "kind", "schemaVersion", "id", "type", "sample", "sequence",
            "offset", "count", "startDate", "endDate", "voltages"
        ]
        XCTAssertTrue(
            legacyFields.isSubset(of: Set(object.keys)),
            "Canonical envelope fields may be added, but existing fields cannot disappear."
        )
        XCTAssertNotNil(object["canonicalId"] as? String)
        XCTAssertNotNil(object["canonicalType"] as? String)
        XCTAssertNotNil(object["parentCanonicalId"] as? String)
    }

    func testAPageFieldCannotDisplaceTheShapesOwnMeaning() throws {
        let change = try SeriesEncoding.elementsChange(
            shape: QuantitySeriesEncoding.shape(for: heartRate.rawValue),
            sample: UUID(),
            offset: 100,
            elements: readings([1, 2]),
            sampleStart: base,
            sampleEnd: base.addingTimeInterval(10),
            extra: ["offset": 0, "count": 999, "unit": unit]
        )
        let object = try object(change)
        XCTAssertEqual(object["offset"] as? Int, 100)
        XCTAssertEqual(object["count"] as? Int, 2)
        XCTAssertEqual(object["unit"] as? String, unit)
    }
}
