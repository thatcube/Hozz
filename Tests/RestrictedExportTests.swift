import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// Picking GPX used to read all two hundred Health types into the spool and
/// then throw almost all of it away at assembly. Correct, and slow enough to
/// look broken: someone wanting a few GPS tracks waited for their entire
/// health history.
final class RestrictedExportTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let workout = HealthTypeKey("HKWorkoutTypeIdentifier")
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heart = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func upsert(_ identifier: String, type: HealthTypeKey) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(identifier)"}"#.utf8
                )
            )
        )
    }

    // MARK: - What a format needs

    func testGPXReadsOnlyWhatAGPXFileCanHold() {
        let required = try? XCTUnwrap(HealthExportFormat.gpx.requiredTypes)

        XCTAssertEqual(
            required,
            [workout, WorkoutRouteEncoding.typeKey],
            "A GPX file holds routes, named by their workout, and nothing else."
        )
    }

    func testEveryOtherFormatReadsEverything() {
        for format in HealthExportFormat.allCases where format != .gpx {
            XCTAssertNil(
                format.requiredTypes,
                "\(format.rawValue) presents the whole of Health and must not narrow."
            )
        }
    }

    func testNarrowingKeepsOnlyTheTypesTheFormatAsksFor() {
        let all = HealthKitTypeRegistry.exportableTypes()
        XCTAssertGreaterThan(all.count, 100)

        let narrowed = HealthKitManualExporter.types(for: .gpx, from: all)
        let everything = HealthKitManualExporter.types(for: .ndjson, from: all)

        XCTAssertEqual(
            Set(narrowed.map(\.catalogEntry.key)),
            [workout, WorkoutRouteEncoding.typeKey]
        )
        XCTAssertEqual(everything.count, all.count)
    }

    // MARK: - What a restricted run actually does

    private func makeEngine(
        store: HozzStore,
        source: any HealthDataSource,
        types: [HealthTypeKey]
    ) -> HealthExportEngine {
        HealthExportEngine(
            store: store,
            source: source,
            types: types,
            batchSize: 100,
            lease: ExportWriterLease()
        )
    }

    func testARestrictedRunNeverReadsTheTypesItLeftOut() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [
                workout: [upsert("w-0", type: workout)],
                steps: (0..<50).map { upsert("s-\($0)", type: steps) },
                heart: (0..<50).map { upsert("h-\($0)", type: heart) }
            ]
        )
        let engine = makeEngine(store: store, source: source, types: [workout])

        _ = try await engine.export(format: .gpx) { _ in }

        let stepQueries = await source.queryCount(for: steps)
        let heartQueries = await source.queryCount(for: heart)
        XCTAssertEqual(
            stepQueries,
            0,
            "A type the run left out must not be read at all, not read and discarded."
        )
        XCTAssertEqual(heartQueries, 0)
        let workoutQueries = await source.queryCount(for: workout)
        XCTAssertGreaterThan(workoutQueries, 0)
    }

    /// A three-type run must say three, not look stuck at a fraction of two
    /// hundred. The progress sites all count the run's own types, so this is
    /// only true if the engine is given the narrowed list rather than the full
    /// one plus a filter.
    func testProgressCountsTheRunsOwnTypesRatherThanTheCatalogue() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [workout: [upsert("w-0", type: workout)]]
        )
        let engine = makeEngine(store: store, source: source, types: [workout])

        let totals = Totals()
        let outcome = try await engine.export(format: .gpx) { progress in
            await totals.record(progress.totalTypes)
        }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertEqual(result.attemptedTypeCount, 1)
        let seen = await totals.seen
        XCTAssertEqual(
            seen,
            [1],
            "Progress must be out of what this run reads, not out of everything."
        )
        XCTAssertGreaterThan(
            result.catalogTypeCount,
            result.attemptedTypeCount,
            "The catalogue count stays honest about how much Health there is."
        )
    }

    /// The reason narrowing is safe rather than merely faster: a manual export
    /// keeps its cursors under its own run, so a restricted run cannot advance
    /// one that a full export or a destination depends on.
    func testARestrictedRunLeavesOtherScopesCursorsAlone() async throws {
        let store = try makeStore()
        let destination = UUID()
        try await store.recordCoverage(
            scope: .destination(destination),
            type: steps,
            coverage: .draining,
            failureReason: nil
        )

        let source = ScriptedHealthDataSource(
            streams: [
                workout: [upsert("w-0", type: workout)],
                steps: (0..<10).map { upsert("s-\($0)", type: steps) }
            ]
        )
        let engine = makeEngine(store: store, source: source, types: [workout])
        _ = try await engine.export(format: .gpx) { _ in }

        let untouched = try await store.streamRecord(
            scope: .destination(destination),
            type: steps
        )
        XCTAssertEqual(untouched?.coverage, .draining)
        XCTAssertNil(
            untouched?.committedAnchor,
            "A narrowed run must not move a cursor it does not own."
        )
        let stepQueries = await source.queryCount(for: steps)
        XCTAssertEqual(stepQueries, 0)
    }

    private actor Totals {
        private(set) var seen: Set<Int> = []

        func record(_ total: Int) {
            seen.insert(total)
        }
    }
}
