import HealthKit
import HozzCatalog
import HozzCore
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
    private var factsCalls = 0
    private var readingsCalls = 0
    private var readingsDelivered = 0

    init(
        series: [UUID: [QuantityReading]],
        facts: [UUID: SeriesFacts],
        batchSize: Int = 64
    ) {
        self.storedSeries = series
        self.storedFacts = facts
        self.batchSize = batchSize
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
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < all.count {
                let end = min(index + size, all.count)
                let batch = Array(all[index..<end])
                self.lock.withLock { self.readingsDelivered += batch.count }
                continuation.yield(batch)
                index = end
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
        _ changes: [HealthChange]
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

        var expected = 0
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
        let elements = readings(literalValues)
        let parent = facts(for: elements)
        let backend = makeBackend(sample, values: literalValues)

        let run = try await drainToCompletion(
            sample: sample,
            backend: backend,
            recordLimit: 8
        )
        let exported = try exportedReadings(run.changes)
        XCTAssertFalse(exported.isEmpty)

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
        }
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
            SeriesEncoding.identifier(
                shape: QuantitySeriesEncoding.shape(for: heartRate.rawValue),
                sample: sample,
                suffix: "error"
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
        XCTAssertEqual(
            Set(object.keys),
            [
                "kind", "schemaVersion", "id", "type", "sample", "sequence",
                "offset", "count", "startDate", "endDate", "voltages"
            ],
            """
            A caller that passes no extra fields must get exactly the record \
            it got before, or every electrocardiogram page already delivered \
            stops matching the one that replaces it.
            """
        )
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
