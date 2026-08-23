import CoreLocation
import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzStore
import XCTest
@testable import HozzHealth

/// A route backend with a fixed set of routes, so the paging that could lose
/// or duplicate points can be exercised without a device that has any rides.
private actor FakeRouteBackend: SeriesBackend {
    struct Route {
        let id: UUID
        let start: Date
        let end: Date
        let locations: [RouteLocation]
        /// How Health chooses to hand the points over.
        let batchSize: Int
    }

    private var routes: [Route]
    private var deletions: [UUID]
    private let link: RouteWorkoutLink
    private var removed: Set<UUID> = []
    private(set) var streamsOpened = 0
    private(set) var pointsRead = 0

    init(
        routes: [Route],
        deletions: [UUID] = [],
        link: RouteWorkoutLink = .resolved(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            activityType: 37,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 3_600)
        )
    ) {
        self.routes = routes
        self.deletions = deletions
        self.link = link
    }

    func remove(_ id: UUID) {
        removed.insert(id)
    }

    func nextPage(after anchor: Data?) async throws -> SeriesPage {
        let offset = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let pendingDeletions = offset == 0 ? deletions : []

        guard offset < routes.count else {
            return SeriesPage(
                header: nil,
                deletions: pendingDeletions,
                anchor: Data(String(offset).utf8)
            )
        }

        let route = routes[offset]
        let base = try JSONSerialization.data(
            withJSONObject: [
                "startDate": Timestamps.text(route.start),
                "endDate": Timestamps.text(route.end),
                "metadata": [:],
                "source": ["name": "Watch", "bundleIdentifier": "com.apple.health"]
            ] as [String: Any],
            options: [.sortedKeys]
        )
        return SeriesPage(
            header: SeriesHeader(
                id: route.id,
                startDate: route.start,
                endDate: route.end,
                basePayload: try WorkoutRouteEncoding.basePayload(
                    base,
                    workout: link
                )
            ),
            deletions: pendingDeletions,
            anchor: Data(String(offset + 1).utf8)
        )
    }

    func facts(id: UUID) async throws -> SeriesFacts? {
        guard !removed.contains(id), let route = routes.first(where: { $0.id == id }) else {
            return nil
        }
        return SeriesFacts(startDate: route.start, endDate: route.end)
    }

    nonisolated func elements(
        for routeID: UUID
    ) -> AsyncThrowingStream<[RouteLocation], any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.deliver(routeID, to: continuation)
            }
        }
    }

    private func deliver(
        _ routeID: UUID,
        to continuation: AsyncThrowingStream<[RouteLocation], any Error>.Continuation
    ) {
        streamsOpened += 1
        guard !removed.contains(routeID), let route = routes.first(where: { $0.id == routeID }) else {
            continuation.finish()
            return
        }
        var index = 0
        while index < route.locations.count {
            let end = min(index + route.batchSize, route.locations.count)
            let batch = Array(route.locations[index..<end])
            pointsRead += batch.count
            continuation.yield(batch)
            index = end
        }
        continuation.finish()
    }

}

private enum Timestamps {
    static func text(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}

final class WorkoutRouteTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let routeType = WorkoutRouteEncoding.typeKey

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func locations(
        _ count: Int,
        from start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [RouteLocation] {
        (0..<count).map { index in
            RouteLocation(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 51.5 + Double(index) / 100_000,
                longitude: -0.1 - Double(index) / 100_000,
                altitude: 10 + Double(index) / 10,
                horizontalAccuracy: 4,
                verticalAccuracy: 3,
                course: 90,
                courseAccuracy: 5,
                speed: 3.5,
                speedAccuracy: 0.5
            )
        }
    }

    private func route(
        id: UUID = UUID(),
        pointCount: Int,
        batchSize: Int = 137,
        startOffset: TimeInterval = 0
    ) -> FakeRouteBackend.Route {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + startOffset)
        return FakeRouteBackend.Route(
            id: id,
            start: start,
            end: start.addingTimeInterval(Double(pointCount)),
            locations: locations(pointCount, from: start),
            batchSize: batchSize
        )
    }

    /// Points in one drain page. A route has to be longer than this to be
    /// interrupted part-way through at all.
    private var pointsPerPage: Int {
        WorkoutRouteEncoding.locationsPerRecord
            * WorkoutRouteEncoding.recordsPerPage
    }

    /// Drains a route type to exhaustion the way ``DrainCoordinator`` does,
    /// returning every record in order.
    private func drainAll(
        _ reader: SeriesReader<FakeRouteBackend>,
        limit: Int = 1_000
    ) async throws -> [[String: Any]] {
        var anchor: AnchorToken?
        var records: [[String: Any]] = []
        var queries = 0

        while queries < 5_000 {
            let batch = try await reader.changes(after: anchor, limit: limit)
            queries += 1
            if batch.changes.isEmpty {
                return records
            }
            XCTAssertNotEqual(
                batch.proposedAnchor,
                anchor,
                "A page with records must move the cursor, or the drain loops forever."
            )
            records.append(contentsOf: try Self.objects(in: batch))
            anchor = batch.proposedAnchor
        }
        XCTFail("The route drain never reached an empty page.")
        return records
    }

    private static func objects(
        in batch: HealthChangeBatch
    ) throws -> [[String: Any]] {
        try batch.changes.map { change in
            switch change {
            case .upsert(let object):
                guard
                    let parsed = try JSONSerialization.jsonObject(
                        with: object.canonicalPayload
                    ) as? [String: Any]
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return parsed
            case .delete(let deletion):
                return [
                    "kind": "deletion",
                    "id": deletion.id.uuidString.lowercased()
                ]
            }
        }
    }

    private func points(in records: [[String: Any]]) -> [String] {
        records
            .filter { $0["kind"] as? String == "workoutRouteLocations" }
            .flatMap { record in
                (record["locations"] as? [[String: Any]] ?? []).map {
                    $0["timestamp"] as? String ?? ""
                }
            }
    }

    // MARK: - Completeness

    func testEveryPointOfARouteIsWrittenOnceAndInOrder() async throws {
        let id = UUID()
        let pointCount = 1_234
        let backend = FakeRouteBackend(routes: [route(id: id, pointCount: pointCount)])
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let records = try await drainAll(reader)
        let timestamps = points(in: records)

        XCTAssertEqual(timestamps.count, pointCount)
        XCTAssertEqual(Set(timestamps).count, pointCount, "No point may repeat.")
        XCTAssertEqual(
            timestamps,
            locations(pointCount).map { Timestamps.text($0.timestamp) },
            "A route read out of order is a route that never happened."
        )
    }

    func testARouteIsWrittenAsAHeaderPagesAndAnEnd() async throws {
        let id = UUID()
        let backend = FakeRouteBackend(routes: [route(id: id, pointCount: 1_001)])
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let records = try await drainAll(reader)
        let kinds = records.compactMap { $0["kind"] as? String }

        XCTAssertEqual(kinds.first, "workoutRoute")
        XCTAssertEqual(kinds.last, "workoutRouteEnd")
        XCTAssertEqual(
            kinds.filter { $0 == "workoutRouteLocations" }.count,
            3,
            "1001 points at 500 per record is two full records and a tail."
        )
        XCTAssertEqual(
            records.last?["locations"] as? Int,
            1_001,
            "The end marker is how a reader tells a whole route from a truncated one."
        )
    }

    func testEveryLocationPageIsFullExceptTheLast() async throws {
        let backend = FakeRouteBackend(
            routes: [route(pointCount: 1_700, batchSize: 61)]
        )
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let pages = try await drainAll(reader)
            .filter { $0["kind"] as? String == "workoutRouteLocations" }

        XCTAssertEqual(pages.count, 4)
        for page in pages.dropLast() {
            XCTAssertEqual(
                page["count"] as? Int,
                WorkoutRouteEncoding.locationsPerRecord,
                "A short page mid-route shifts every later offset."
            )
        }
        XCTAssertEqual(pages.last?["count"] as? Int, 200)
        XCTAssertEqual(
            pages.map { $0["offset"] as? Int },
            [0, 500, 1_000, 1_500]
        )
    }

    func testSeveralRoutesAreKeptApart() async throws {
        let first = UUID()
        let second = UUID()
        let backend = FakeRouteBackend(
            routes: [
                route(id: first, pointCount: 600),
                route(id: second, pointCount: 250)
            ]
        )
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let records = try await drainAll(reader)
        let firstPoints = records.filter {
            $0["sample"] as? String == first.uuidString.lowercased()
                && $0["kind"] as? String == "workoutRouteLocations"
        }
        let secondPoints = records.filter {
            $0["sample"] as? String == second.uuidString.lowercased()
                && $0["kind"] as? String == "workoutRouteLocations"
        }

        XCTAssertEqual(
            firstPoints.compactMap { $0["count"] as? Int }.reduce(0, +),
            600
        )
        XCTAssertEqual(
            secondPoints.compactMap { $0["count"] as? Int }.reduce(0, +),
            250
        )
    }

    func testDeletedRoutesAreCarriedAsTombstones() async throws {
        let deleted = UUID()
        let backend = FakeRouteBackend(
            routes: [route(pointCount: 10)],
            deletions: [deleted]
        )
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let records = try await drainAll(reader)

        XCTAssertTrue(
            records.contains {
                $0["kind"] as? String == "deletion"
                    && $0["id"] as? String == deleted.uuidString.lowercased()
            },
            "A route removed from Health must not stay in the export forever."
        )
    }

    // MARK: - Interruption

    /// A relaunch has no live stream, so it re-opens the route and skips what
    /// is already durable. This is the case that would otherwise duplicate or
    /// drop points.
    func testResumingMidRouteNeitherRepeatsNorSkipsAPoint() async throws {
        let id = UUID()
        let pointCount = pointsPerPage * 2 + 137
        let backend = FakeRouteBackend(
            routes: [route(id: id, pointCount: pointCount, batchSize: 173)]
        )

        // Read part of the route, then throw the reader away, as a kill would.
        let first = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        var anchor: AnchorToken?
        var records: [[String: Any]] = []
        for _ in 0..<2 {
            let batch = try await first.changes(after: anchor, limit: 1_000)
            records.append(contentsOf: try Self.objects(in: batch))
            anchor = batch.proposedAnchor
        }
        let carried = try SeriesAnchor.decode(anchor)
        XCTAssertEqual(carried.pendingSample, id)
        XCTAssertGreaterThan(carried.deliveredElements, 0)
        XCTAssertLessThan(carried.deliveredElements, pointCount)

        // A fresh reader over the same cursor is what relaunching looks like.
        let second = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        while true {
            let batch = try await second.changes(after: anchor, limit: 1_000)
            if batch.changes.isEmpty {
                break
            }
            records.append(contentsOf: try Self.objects(in: batch))
            anchor = batch.proposedAnchor
        }

        let timestamps = points(in: records)
        XCTAssertEqual(timestamps.count, pointCount, "No point may be skipped.")
        XCTAssertEqual(
            Set(timestamps).count,
            pointCount,
            "No point may be written twice."
        )
        XCTAssertEqual(
            timestamps,
            locations(pointCount).map { Timestamps.text($0.timestamp) }
        )
    }

    /// The identifiers a receiver dedupes on must not depend on where a run
    /// happened to be interrupted.
    func testAReplayedPageCarriesTheSameIdentifiers() async throws {
        let id = UUID()
        let routes = [route(id: id, pointCount: pointsPerPage * 2 + 137, batchSize: 97)]

        let straight = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: FakeRouteBackend(routes: routes))
        let whole = try await drainAll(straight)

        let backend = FakeRouteBackend(routes: routes)
        let interrupted = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        var anchor: AnchorToken?
        var pieces: [[String: Any]] = []
        var reader = interrupted
        var pages = 0
        while true {
            let batch = try await reader.changes(after: anchor, limit: 1_000)
            if batch.changes.isEmpty {
                break
            }
            pieces.append(contentsOf: try Self.objects(in: batch))
            anchor = batch.proposedAnchor
            pages += 1
            // Drop the reader every page, so every page after the first is a
            // re-opened stream.
            reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        }

        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(
            pieces.compactMap { $0["id"] as? String },
            whole.compactMap { $0["id"] as? String },
            "The same page of the same route must always be the same record."
        )
    }

    func testTheOrdinaryPathReadsEachPointOnlyOnce() async throws {
        let backend = FakeRouteBackend(
            routes: [route(pointCount: pointsPerPage * 2 + 137, batchSize: 100)]
        )
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        _ = try await drainAll(reader)

        let read = await backend.pointsRead
        let opened = await backend.streamsOpened
        XCTAssertEqual(
            read,
            pointsPerPage * 2 + 137,
            "Keeping the stream open between pages is what avoids re-reading a ride."
        )
        XCTAssertEqual(opened, 1)
    }

    func testARouteThatDisappearsMidReadIsReportedRatherThanTruncated() async throws {
        let id = UUID()
        let backend = FakeRouteBackend(
            routes: [route(id: id, pointCount: pointsPerPage * 2 + 137, batchSize: 100)]
        )

        let first = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        var anchor: AnchorToken?
        for _ in 0..<2 {
            let batch = try await first.changes(after: anchor, limit: 1_000)
            anchor = batch.proposedAnchor
        }
        await backend.remove(id)

        let second = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        let batch = try await second.changes(after: anchor, limit: 1_000)
        let records = try Self.objects(in: batch)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["kind"] as? String, "sampleEncodingError")
        XCTAssertEqual(records[0]["id"] as? String, id.uuidString.lowercased())

        let after = try SeriesAnchor.decode(batch.proposedAnchor)
        XCTAssertNil(
            after.pendingSample,
            "A route that cannot be finished must not block every route behind it."
        )
    }

    // MARK: - Anchors

    func testARouteCursorSurvivesEncoding() throws {
        let id = UUID()
        let anchor = SeriesAnchor(
            healthKitAnchor: Data([1, 2, 3]),
            pendingSample: id,
            deliveredElements: 1_500
        )

        let restored = try SeriesAnchor.decode(try anchor.token())

        XCTAssertEqual(restored, anchor)
    }

    func testAnEmptyCursorMeansTheStart() throws {
        XCTAssertEqual(try SeriesAnchor.decode(nil), .start)
    }

    func testAMalformedRouteCursorIsRejectedRatherThanReset() {
        XCTAssertThrowsError(
            try SeriesAnchor.decode(AnchorToken(data: Data("nonsense".utf8)))
        )
    }

    func testAnOffsetWithoutARouteIsRejected() throws {
        let token = AnchorToken(
            data: try JSONSerialization.data(
                withJSONObject: ["v": 1, "offset": 500]
            )
        )

        XCTAssertThrowsError(
            try SeriesAnchor.decode(token),
            "An offset with no route would skip the start of whichever route came next."
        )
    }

    // MARK: - Encoding

    func testAPointWithNoFixOmitsTheFieldsItDoesNotHave() {
        let location = RouteLocation(
            timestamp: Date(timeIntervalSince1970: 0),
            latitude: 1,
            longitude: 2,
            altitude: 99,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            course: -1,
            courseAccuracy: -1,
            speed: -1,
            speedAccuracy: -1
        )

        let object = location.seriesObject

        XCTAssertEqual(object["latitude"] as? Double, 1)
        XCTAssertNil(object["altitude"], "An unknown altitude is not a measurement of 99.")
        XCTAssertNil(object["horizontalAccuracy"])
        XCTAssertNil(object["course"])
        XCTAssertNil(object["speed"])
    }

    func testACoreLocationPointConvertsWithoutLosingItsFix() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            altitude: 42,
            horizontalAccuracy: 5,
            verticalAccuracy: 6,
            course: 180,
            speed: 2.5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let converted = RouteLocation(location)

        XCTAssertEqual(converted.latitude, 51.5)
        XCTAssertEqual(converted.longitude, -0.1)
        XCTAssertEqual(converted.altitude, 42)
        XCTAssertEqual(converted.horizontalAccuracy, 5)
        XCTAssertEqual(converted.course, 180)
        XCTAssertEqual(converted.speed, 2.5)
    }

    func testARouteRecordCarriesDatesTheReceiverNeeds() async throws {
        let backend = FakeRouteBackend(routes: [route(pointCount: 600)])
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let records = try await drainAll(reader)
        for record in records where record["kind"] as? String != "deletion" {
            XCTAssertNotNil(
                record["startDate"] as? String,
                "A record with no dates is counted as unreadable by the receiver and never resent."
            )
            XCTAssertNotNil(record["endDate"] as? String)
            XCTAssertEqual(
                record["type"] as? String,
                WorkoutRouteEncoding.typeIdentifier
            )
        }
    }

    func testAnUnresolvedWorkoutSaysSoRatherThanGuessing() async throws {
        let backend = FakeRouteBackend(
            routes: [route(pointCount: 10)],
            link: .unresolved(reason: "No overlapping workout claims this route.")
        )
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let header = try await drainAll(reader)
            .first { $0["kind"] as? String == "workoutRoute" }
        let workout = try XCTUnwrap(header?["workout"] as? [String: Any])

        XCTAssertEqual(workout["state"] as? String, "unresolved")
        XCTAssertNil(workout["id"], "An unresolved link must not name a workout.")
    }

    func testAResolvedWorkoutIsNamedOnTheRoute() async throws {
        let backend = FakeRouteBackend(routes: [route(pointCount: 10)])
        let reader = SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)

        let header = try await drainAll(reader)
            .first { $0["kind"] as? String == "workoutRoute" }
        let workout = try XCTUnwrap(header?["workout"] as? [String: Any])

        XCTAssertEqual(workout["state"] as? String, "resolved")
        XCTAssertEqual(
            workout["id"] as? String,
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(workout["activityType"] as? Int, 37)
    }

    // MARK: - Through an export

    /// Wires the route reader in where ``HealthKitHealthDataSource`` would, so
    /// the export, the spool, and the transcoders all see real route records.
    private struct RouteOnlySource: HealthDataSource {
        let reader: SeriesReader<FakeRouteBackend>

        func changes(
            for type: HealthTypeKey,
            after anchor: AnchorToken?,
            limit: Int
        ) async throws -> HealthChangeBatch {
            try await reader.changes(after: anchor, limit: limit)
        }
    }

    func testAnExportCarriesEveryPointOfEveryRoute() async throws {
        let store = try makeStore()
        let backend = FakeRouteBackend(
            routes: [
                route(pointCount: 900),
                route(pointCount: 1_100, startOffset: 100_000)
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: RouteOnlySource(reader: SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)),
            types: [routeType],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let records = try ExportArtifactReader.records(in: result.fileURL)
        let timestamps = points(in: records)
        XCTAssertEqual(timestamps.count, 2_000)
        XCTAssertEqual(Set(timestamps).count, 2_000)
        XCTAssertEqual(
            records.filter { $0["kind"] as? String == "workoutRoute" }.count,
            2
        )
        XCTAssertEqual(
            records.filter { $0["kind"] as? String == "workoutRouteEnd" }.count,
            2
        )
        XCTAssertEqual(result.nonEmptyTypeCount, 1)
    }

    func testCSVKeepsOnePointPerRowRatherThanOneUnreadableCell() async throws {
        let store = try makeStore()
        let id = UUID()
        let backend = FakeRouteBackend(routes: [route(id: id, pointCount: 750)])
        let engine = HealthExportEngine(
            store: store,
            source: RouteOnlySource(reader: SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)),
            types: [routeType],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)

        let locationsCSV = try XCTUnwrap(entries["WorkoutRouteLocations.csv"])
        let locationRows = String(decoding: locationsCSV, as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(
            locationRows.count,
            751,
            "Every point needs its own row, plus the header."
        )
        XCTAssertTrue(
            locationRows[0].hasPrefix("route,sequence,offset,timestamp,latitude,longitude")
        )
        XCTAssertEqual(
            locationRows.dropFirst().compactMap { row in
                row.split(separator: ",").dropFirst(2).first.map(String.init)
            },
            (0..<750).map(String.init),
            "Offsets must run straight through, or points were dropped."
        )

        let routesCSV = try XCTUnwrap(entries["WorkoutRoutes.csv"])
        let routeRows = String(decoding: routesCSV, as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(routeRows.count, 2)
        XCTAssertTrue(routeRows[1].contains(id.uuidString.lowercased()))
        XCTAssertTrue(
            routeRows[1].split(separator: ",").contains("750"),
            "The route's row should say how many points it actually holds."
        )
    }

    func testAKilledExportResumesARouteWithoutGapsOrDuplicates() async throws {
        let store = try makeStore()
        let id = UUID()
        let pointCount = pointsPerPage * 2 + 137
        let backend = FakeRouteBackend(
            routes: [route(id: id, pointCount: pointCount, batchSize: 211)]
        )

        // Seal a part part-way through the route, then walk away from it.
        let run = try await store.createRun(
            format: HealthExportFormat.ndjson.rawValue,
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        let sink = SpooledExportSink(
            store: store,
            runID: run.id,
            format: .ndjson,
            spoolDirectory: await store.spoolDirectory,
            nextSequence: 0,
            totalRecordCount: 0
        )
        let source = RouteOnlySource(
            reader: SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)
        )
        var anchor: AnchorToken?
        for _ in 0..<2 {
            let batch = try await source.changes(
                for: routeType,
                after: anchor,
                limit: 1_000
            )
            try await sink.commit(batch, for: routeType, baseAnchor: anchor)
            anchor = batch.proposedAnchor
        }
        try await sink.seal()
        let sealed = try await store.committedAnchor(
            scope: .run(run.id),
            type: routeType
        )
        let carried = try SeriesAnchor.decode(sealed)
        XCTAssertEqual(
            carried.pendingSample,
            id,
            "The cursor has to remember which route was half-written."
        )

        // A fresh engine over the same store is what relaunching looks like.
        let engine = HealthExportEngine(
            store: store,
            source: RouteOnlySource(reader: SeriesReader(shape: WorkoutRouteEncoding.shape, backend: backend)),
            types: [routeType],
            lease: ExportWriterLease()
        )
        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The resumed run should have completed.")
        }
        XCTAssertTrue(result.wasResumed)

        let timestamps = points(in: try ExportArtifactReader.records(in: result.fileURL))
        XCTAssertEqual(timestamps.count, pointCount, "No point may be lost.")
        XCTAssertEqual(
            Set(timestamps).count,
            pointCount,
            "No point may be written twice."
        )
        XCTAssertEqual(
            timestamps,
            locations(pointCount).map { Timestamps.text($0.timestamp) }
        )
    }

    // MARK: - Catalog and registry

    func testTheRouteTypeIsCataloguedAndExportable() {
        let entry = HealthTypeCatalog.entriesByIdentifier[
            WorkoutRouteEncoding.typeIdentifier
        ]

        XCTAssertEqual(entry?.family, .series)
        XCTAssertEqual(entry?.displayName, "Workout Route")
        XCTAssertTrue(
            HealthKitTypeRegistry.exportableTypes().contains {
                $0.catalogEntry.key == WorkoutRouteEncoding.typeKey
            },
            "A route Hozz can read must be one it offers."
        )
    }
}
