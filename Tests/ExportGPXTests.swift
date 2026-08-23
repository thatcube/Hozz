import Foundation
import XCTest
@testable import HozzHealth

/// A parsed XML element, built with `XMLParser`.
///
/// The tests read the GPX back rather than matching strings. A string
/// comparison proves the bytes did not change; parsing proves the file is
/// well-formed, that the escaping is reversible, and that the elements sit in
/// the order GPX 1.1 requires — which is what decides whether another tool
/// opens it.
final class XMLElement2 {
    let name: String
    let namespace: String?
    let attributes: [String: String]
    private(set) var children: [XMLElement2] = []
    private(set) var text = ""
    weak var parent: XMLElement2?

    init(name: String, namespace: String?, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    func add(_ child: XMLElement2) {
        child.parent = self
        children.append(child)
    }

    func append(_ value: String) {
        text += value
    }

    func children(_ name: String) -> [XMLElement2] {
        children.filter { $0.name == name }
    }

    func first(_ name: String) -> XMLElement2? {
        children(name).first
    }

    /// Every descendant with this name, at any depth.
    func all(_ name: String) -> [XMLElement2] {
        var found: [XMLElement2] = []
        if self.name == name {
            found.append(self)
        }
        for child in children {
            found.append(contentsOf: child.all(name))
        }
        return found
    }

    var childNames: [String] {
        children.map(\.name)
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLElement2?
    private var stack: [XMLElement2] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let element = XMLElement2(
            name: elementName,
            namespace: namespaceURI,
            attributes: attributes
        )
        if let current = stack.last {
            current.add(element)
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        stack.removeLast()
    }
}

final class ExportGPXTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let timeZone = TimeZone(identifier: "America/New_York")!
    private let routeType = "HKWorkoutRouteTypeIdentifier"

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - Fixtures

    /// Pages are addressed by absolute offset, and a page's offset is the
    /// running total of the points before it. The real page holds 500 points;
    /// these hold a handful, which exercises the same arithmetic without
    /// putting thousands of coordinates in a test.
    private func page(
        route: String,
        offset: Int,
        points: [[String: Any]],
        count: Int? = nil
    ) -> [String: Any] {
        [
            "kind": "workoutRouteLocations",
            "schemaVersion": 1,
            "id": UUID().uuidString.lowercased(),
            "type": routeType,
            "sample": route,
            "sequence": offset,
            "offset": offset,
            "count": count ?? points.count,
            "startDate": "2026-08-22T11:00:00.000Z",
            "endDate": "2026-08-22T11:05:00.000Z",
            "locations": points
        ]
    }

    private func location(
        latitude: Double = 51.5007,
        longitude: Double = -0.1246,
        altitude: Double? = 11.2,
        second: Int = 0,
        speed: Double? = 3.1,
        course: Double? = 182
    ) -> [String: Any] {
        var object: [String: Any] = [
            "timestamp": String(
                format: "2026-08-22T11:00:%02d.000Z",
                second
            ),
            "latitude": latitude,
            "longitude": longitude
        ]
        if let altitude {
            object["altitude"] = altitude
            object["verticalAccuracy"] = 3.0
        }
        if let speed {
            object["speed"] = speed
        }
        if let course {
            object["course"] = course
        }
        object["horizontalAccuracy"] = 4.1
        return object
    }

    private func header(
        route: String,
        workout: String? = "5a4f0000-0000-4000-8000-000000000001",
        activityType: Int? = 37,
        unresolvedReason: String? = nil,
        start: String = "2026-08-22T11:00:00.000Z",
        end: String = "2026-08-22T11:30:00.000Z",
        source: String = "Apple Watch"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "workoutRoute",
            "schemaVersion": 1,
            "id": route,
            "type": routeType,
            "startDate": start,
            "endDate": end,
            "metadata": [:],
            "source": ["name": source, "bundleIdentifier": "com.apple.health"]
        ]
        if let reason = unresolvedReason {
            object["workout"] = ["state": "unresolved", "reason": reason]
        } else if let workout, let activityType {
            object["workout"] = [
                "state": "resolved",
                "id": workout,
                "activityType": activityType,
                "startDate": start,
                "endDate": end
            ]
        }
        return object
    }

    private func end(route: String, total: Int) -> [String: Any] {
        [
            "kind": "workoutRouteEnd",
            "schemaVersion": 1,
            "id": UUID().uuidString.lowercased(),
            "type": routeType,
            "sample": route,
            "locations": total,
            "startDate": "2026-08-22T11:00:00.000Z",
            "endDate": "2026-08-22T11:30:00.000Z"
        ]
    }

    private func workout(
        id: String = "5a4f0000-0000-4000-8000-000000000001",
        activityType: Int = 37,
        duration: Double = 1_800,
        source: String = "Apple Watch"
    ) -> [String: Any] {
        [
            "kind": "workout",
            "schemaVersion": 1,
            "id": id,
            "type": "HKWorkoutTypeIdentifier",
            "startDate": "2026-08-22T11:00:00.000Z",
            "endDate": "2026-08-22T11:30:00.000Z",
            "activityType": activityType,
            "duration": duration,
            "events": [],
            "metadata": [:],
            "source": ["name": source, "bundleIdentifier": "com.apple.health"]
        ]
    }

    // MARK: - Harness

    private func build(
        _ lines: [[String: Any]]
    ) throws -> (entries: [String: Data], statistics: ExportGPXStatistics) {
        let source = directory.url.appending(path: "spool-\(UUID().uuidString).ndjson")
        var data = Data()
        for line in lines {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: line,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            data.append(0x0A)
        }
        try data.write(to: source)

        let destination = directory.url.appending(path: "gpx-\(UUID().uuidString).zip")
        let archive = try ZipStreamWriter(
            destinationURL: destination,
            modifiedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let statistics = try ExportGPXWriter.write(
            readingFrom: source,
            into: archive,
            metadata: ExportGPXWriter.Metadata(
                runID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_767_225_600),
                timeZone: timeZone
            )
        )
        _ = try archive.finish()
        return (try ExportArtifactReader.readZipEntries(at: destination), statistics)
    }

    /// Parses an entry, failing the test if it is not well-formed XML.
    private func parse(
        _ entries: [String: Data],
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XMLElement2 {
        let data = try XCTUnwrap(
            entries[name],
            "There is no \(name). Entries: \(entries.keys.sorted())",
            file: file,
            line: line
        )
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        XCTAssertTrue(
            parser.parse(),
            "\(name) is not well-formed XML: "
            + String(describing: parser.parserError),
            file: file,
            line: line
        )
        return try XCTUnwrap(builder.root, file: file, line: line)
    }

    private func gpxNames(_ entries: [String: Data]) -> [String] {
        entries.keys.filter { $0.hasSuffix(".gpx") }.sorted()
    }

    private func readme(_ entries: [String: Data]) throws -> String {
        String(decoding: try XCTUnwrap(entries["README.md"]), as: UTF8.self)
    }

    private func trackPoints(_ root: XMLElement2) -> [XMLElement2] {
        root.all("trkpt")
    }

    // MARK: - A complete route

    private func completeRoute(id: String = "11110000-0000-4000-8000-000000000001")
        -> [[String: Any]] {
        [
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [
                location(second: 0),
                location(latitude: 51.5008, second: 1)
            ]),
            page(route: id, offset: 2, points: [
                location(latitude: 51.5009, second: 2)
            ]),
            end(route: id, total: 3)
        ]
    }

    func testARouteBecomesOneWellFormedGPXFile() throws {
        let (entries, statistics) = try build(completeRoute())

        XCTAssertEqual(gpxNames(entries).count, 1)
        XCTAssertEqual(statistics.trackCount, 1)
        XCTAssertEqual(statistics.pointCount, 3)
        XCTAssertEqual(statistics.incompleteTrackCount, 0)

        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        XCTAssertEqual(root.name, "gpx")
        XCTAssertEqual(root.attributes["version"], "1.1")
        XCTAssertEqual(root.namespace, "http://www.topografix.com/GPX/1/1")
        XCTAssertFalse(root.attributes["creator"]?.isEmpty ?? true, "GPX requires a creator.")
    }

    func testTheTrackCarriesItsPointsInOrder() throws {
        let (entries, _) = try build(completeRoute())
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let points = trackPoints(root)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.attributes["lat"], "51.5007")
        XCTAssertEqual(points.first?.attributes["lon"], "-0.1246")
        XCTAssertEqual(
            points.map { $0.first("time")?.text },
            [
                "2026-08-22T11:00:00.000Z",
                "2026-08-22T11:00:01.000Z",
                "2026-08-22T11:00:02.000Z"
            ]
        )
    }

    /// GPX 1.1 fixes the order of children. Out of order is a file that fails
    /// validation, and strict importers refuse it outright.
    func testElementsSitInTheOrderTheSchemaRequires() throws {
        let (entries, _) = try build(completeRoute())
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))

        XCTAssertEqual(root.childNames, ["metadata", "trk"])
        let metadata = try XCTUnwrap(root.first("metadata"))
        XCTAssertEqual(metadata.childNames, ["name", "desc", "time"])

        let track = try XCTUnwrap(root.first("trk"))
        // name, desc and type all come before any segment.
        let segmentIndex = try XCTUnwrap(track.childNames.firstIndex(of: "trkseg"))
        XCTAssertEqual(
            Array(track.childNames.prefix(segmentIndex)),
            ["name", "desc", "type"]
        )

        let point = try XCTUnwrap(trackPoints(root).first)
        XCTAssertEqual(point.childNames, ["ele", "time", "extensions"])
    }

    func testTheTrackSaysWhatKindOfWorkoutItWas() throws {
        let (entries, _) = try build(completeRoute())
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let track = try XCTUnwrap(root.first("trk"))

        XCTAssertEqual(track.first("type")?.text, "Running")
        XCTAssertTrue(track.first("name")?.text.contains("Running") ?? false)
        let description = try XCTUnwrap(track.first("desc")?.text)
        XCTAssertTrue(description.contains("30m"), "Description: \(description)")
        XCTAssertTrue(description.contains("Apple Watch"), "Description: \(description)")
        XCTAssertFalse(description.contains("Incomplete"))
    }

    /// Speed and course have no element in base GPX. Inventing bare ones makes
    /// the file invalid, so they live in a declared namespace.
    func testSpeedAndCourseAreInAnExtensionNamespaceNotInvented() throws {
        let (entries, _) = try build(completeRoute())
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let extensions = try XCTUnwrap(trackPoints(root).first?.first("extensions"))

        let speed = try XCTUnwrap(extensions.first("speed"))
        XCTAssertEqual(speed.namespace, ExportGPXWriter.extensionNamespace)
        XCTAssertNotEqual(
            speed.namespace,
            "http://www.topografix.com/GPX/1/1",
            "GPX 1.1 only allows extensions from another namespace."
        )
        XCTAssertEqual(speed.text, "3.1")
        XCTAssertEqual(extensions.first("course")?.text, "182")
    }

    func testAltitudeIsWrittenAsElevation() throws {
        let (entries, _) = try build(completeRoute())
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        XCTAssertEqual(trackPoints(root).first?.first("ele")?.text, "11.2")
    }

    // MARK: - Escaping and numbers

    func testTextWithXMLSyntaxInItSurvivesTheRoundTrip() throws {
        let id = "22220000-0000-4000-8000-000000000001"
        let awkward = #"Bran & "Dad" <best> 'watch'"#
        let (entries, _) = try build([
            workout(source: awkward),
            header(route: id, source: awkward),
            page(route: id, offset: 0, points: [location()]),
            end(route: id, total: 1)
        ])

        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let description = try XCTUnwrap(root.first("trk")?.first("desc")?.text)
        XCTAssertTrue(
            description.contains(awkward),
            "The name came back mangled: \(description)"
        )
    }

    func testControlCharactersAreRemovedRatherThanWritten() throws {
        // XML 1.0 has no way to carry these, escaped or not. A file containing
        // one is a file no parser will open.
        XCTAssertEqual(ExportGPXWriter.escaped("a\u{0}b\u{1F}c"), "abc")
        XCTAssertEqual(ExportGPXWriter.escaped("keep\tthis"), "keep\tthis")
        XCTAssertEqual(ExportGPXWriter.escaped("<&>"), "&lt;&amp;&gt;")
    }

    /// A phone set to a language that writes 51,5007 would otherwise produce
    /// coordinates that are not numbers.
    func testDecimalsAreWrittenTheSameWhateverTheLanguage() {
        XCTAssertEqual(ExportGPXWriter.decimal(51.5007, places: 7), "51.5007")
        XCTAssertEqual(ExportGPXWriter.decimal(-0.1246, places: 7), "-0.1246")
        XCTAssertEqual(ExportGPXWriter.decimal(0, places: 3), "0")
        XCTAssertEqual(ExportGPXWriter.decimal(-3.5, places: 3), "-3.5")
        XCTAssertFalse(ExportGPXWriter.decimal(1.5, places: 3).contains(","))
    }

    func testAPointWithoutRealCoordinatesIsLeftOutAndCounted() throws {
        let id = "33330000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [
                location(second: 0),
                // JSON cannot carry a NaN, so the ways a coordinate actually
                // arrives unusable are these: out of range, the wrong type,
                // null, or simply absent.
                location(longitude: 300, second: 1),
                ["timestamp": "2026-08-22T11:00:02.000Z", "latitude": "north", "longitude": 0],
                ["timestamp": "2026-08-22T11:00:03.000Z"],
                location(latitude: 51.5010, second: 4)
            ]),
            end(route: id, total: 5)
        ])

        XCTAssertEqual(statistics.pointCount, 2)
        XCTAssertEqual(statistics.droppedPointCount, 3)

        let name = try XCTUnwrap(gpxNames(entries).first)
        let text = String(decoding: try XCTUnwrap(entries[name]), as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("nan"), "Produced: \(text)")
        // Parsing is the real check: an unusable coordinate that reached the
        // file would take every other track in the archive down with it.
        let root = try parse(entries, name)
        XCTAssertEqual(trackPoints(root).count, 2)
        XCTAssertTrue(try readme(entries).contains("not usable"))
    }

    /// The guard is on the value, not on the spool, because a coordinate that
    /// is not a number must never reach the file whatever it came through.
    func testANonFiniteCoordinateIsRejectedAtTheValue() {
        XCTAssertNil(
            ExportGPXWriter.point(from: ["latitude": Double.nan, "longitude": 0.0])
        )
        XCTAssertNil(
            ExportGPXWriter.point(from: ["latitude": 0.0, "longitude": Double.infinity])
        )
        XCTAssertNil(ExportGPXWriter.point(from: ["latitude": 91.0, "longitude": 0.0]))
        XCTAssertNotNil(ExportGPXWriter.point(from: ["latitude": 0.0, "longitude": 0.0]))
    }

    func testAPointWithNoAltitudeSimplyHasNoElevation() throws {
        let id = "44440000-0000-4000-8000-000000000001"
        let (entries, _) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [
                location(altitude: nil, speed: nil, course: nil)
            ]),
            end(route: id, total: 1)
        ])
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let point = try XCTUnwrap(trackPoints(root).first)
        XCTAssertNil(point.first("ele"))
        XCTAssertNotNil(point.first("time"))
    }

    // MARK: - Incomplete routes

    /// The case this format has to get right. A GPX that joins the two sides of
    /// a gap draws a straight line across a mile of city and looks correct.
    func testAGapInTheMiddleBecomesSeparateSegmentsAndSaysSo() throws {
        let id = "55550000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [location(second: 0)]),
            // The page at offset 1 never arrived.
            page(route: id, offset: 2, points: [location(latitude: 51.6, second: 2)]),
            end(route: id, total: 3)
        ])

        XCTAssertEqual(statistics.incompleteTrackCount, 1)
        XCTAssertEqual(statistics.trackCount, 1)

        let name = try XCTUnwrap(gpxNames(entries).first)
        let root = try parse(entries, name)
        let segments = root.all("trkseg")
        XCTAssertEqual(
            segments.count,
            2,
            "The points either side of a gap must not share a segment."
        )
        XCTAssertEqual(segments.map { $0.all("trkpt").count }, [1, 1])

        let description = try XCTUnwrap(root.first("trk")?.first("desc")?.text)
        XCTAssertTrue(description.contains("Incomplete"), "Description: \(description)")
        XCTAssertTrue(description.contains("gap"), "Description: \(description)")

        let readme = try readme(entries)
        XCTAssertTrue(readme.contains("Incomplete tracks"))
        XCTAssertTrue(readme.contains(name))
    }

    func testAMissingBeginningIsReportedRatherThanStartedFromWhereverItResumes() throws {
        let id = "66660000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 2, points: [location(second: 2)]),
            end(route: id, total: 3)
        ])

        XCTAssertEqual(statistics.incompleteTrackCount, 1)
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let description = try XCTUnwrap(root.first("trk")?.first("desc")?.text)
        XCTAssertTrue(description.contains("Incomplete"), "Description: \(description)")
        XCTAssertTrue(
            description.contains("at the start"),
            "Description: \(description)"
        )
    }

    /// Without an end marker the export never learned how long the route was,
    /// so the tail cannot be vouched for either way.
    func testARouteWithNoEndMarkerIsNeverCalledComplete() throws {
        let id = "77770000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [location()])
        ])

        XCTAssertEqual(statistics.incompleteTrackCount, 1)
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let description = try XCTUnwrap(root.first("trk")?.first("desc")?.text)
        XCTAssertTrue(
            description.contains("never recorded where this route ended"),
            "Description: \(description)"
        )
    }

    func testATailThatNeverArrivedIsReported() throws {
        let id = "88880000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: [location()]),
            end(route: id, total: 10)
        ])

        XCTAssertEqual(statistics.incompleteTrackCount, 1)
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        let description = try XCTUnwrap(root.first("trk")?.first("desc")?.text)
        XCTAssertTrue(description.contains("at the end"), "Description: \(description)")
        XCTAssertTrue(description.contains("9 of 10"), "Description: \(description)")
    }

    /// A route whose pages never arrived produces no file at all. An empty
    /// track is a claim that the ride had no points, which is not what
    /// happened.
    func testARouteWithNoPagesProducesNoFileAndIsListed() throws {
        let id = "99990000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            end(route: id, total: 500)
        ])

        XCTAssertTrue(gpxNames(entries).isEmpty)
        XCTAssertEqual(statistics.trackCount, 0)
        XCTAssertEqual(statistics.emptyRouteCount, 1)
        let readme = try readme(entries)
        XCTAssertTrue(readme.contains("no file"), "README: \(readme)")
    }

    // MARK: - Pages arriving badly

    func testARepeatedPageIsNotWrittenTwice() throws {
        let id = "aaaa0000-0000-4000-8000-000000000001"
        let points = [location(second: 0)]
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: points),
            // A replayed page carries the same offset and the same bytes.
            page(route: id, offset: 0, points: points),
            page(route: id, offset: 1, points: [location(latitude: 51.51, second: 1)]),
            end(route: id, total: 2)
        ])

        XCTAssertEqual(statistics.pointCount, 2)
        XCTAssertEqual(statistics.incompleteTrackCount, 0)
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        XCTAssertEqual(trackPoints(root).count, 2)
        XCTAssertEqual(root.all("trkseg").count, 1)
    }

    func testPagesThatArriveOutOfOrderAreWrittenInOrder() throws {
        let id = "bbbb0000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 2, points: [location(latitude: 51.53, second: 2)]),
            page(route: id, offset: 0, points: [location(latitude: 51.51, second: 0)]),
            page(route: id, offset: 1, points: [location(latitude: 51.52, second: 1)]),
            end(route: id, total: 3)
        ])

        XCTAssertEqual(statistics.incompleteTrackCount, 0, "Out of order is not a gap.")
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        XCTAssertEqual(
            trackPoints(root).map { $0.attributes["lat"] },
            ["51.51", "51.52", "51.53"]
        )
        XCTAssertEqual(root.all("trkseg").count, 1)
    }

    /// The header can arrive after the pages when a run resumed mid-route.
    func testAHeaderThatArrivesAfterItsPagesStillNamesTheTrack() throws {
        let id = "cccc0000-0000-4000-8000-000000000001"
        let (entries, _) = try build([
            page(route: id, offset: 0, points: [location()]),
            end(route: id, total: 1),
            workout(),
            header(route: id)
        ])

        let name = try XCTUnwrap(gpxNames(entries).first)
        XCTAssertTrue(name.contains("running"), "File name: \(name)")
        let root = try parse(entries, name)
        XCTAssertEqual(root.first("trk")?.first("type")?.text, "Running")
    }

    func testRealisticPageOffsetsAreTreatedAsContiguous() throws {
        let id = "dddd0000-0000-4000-8000-000000000001"
        let full = (0..<500).map { location(latitude: 51.5 + Double($0) / 1e5, second: 0) }
        let (entries, statistics) = try build([
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: full),
            page(route: id, offset: 500, points: [location(second: 5)]),
            end(route: id, total: 501)
        ])

        XCTAssertEqual(statistics.pointCount, 501)
        XCTAssertEqual(statistics.incompleteTrackCount, 0)
        let root = try parse(entries, try XCTUnwrap(gpxNames(entries).first))
        XCTAssertEqual(root.all("trkseg").count, 1)
    }

    // MARK: - What does and does not produce a file

    /// A treadmill run has no route. That is not an error and must not produce
    /// an empty track.
    func testAWorkoutWithoutARouteProducesNoFile() throws {
        let (entries, statistics) = try build([
            workout(id: "eeee0000-0000-4000-8000-000000000001", activityType: 37)
        ])

        XCTAssertTrue(gpxNames(entries).isEmpty)
        XCTAssertEqual(statistics.trackCount, 0)
        XCTAssertEqual(statistics.pointCount, 0)
    }

    func testAnExportWithNoRoutesStillExplainsItself() throws {
        let (entries, statistics) = try build([
            [
                "kind": "quantity",
                "schemaVersion": 1,
                "id": UUID().uuidString.lowercased(),
                "type": "HKQuantityTypeIdentifierStepCount",
                "startDate": "2026-08-22T11:00:00.000Z",
                "endDate": "2026-08-22T11:00:00.000Z",
                "quantity": ["unit": "count", "value": 12, "description": "12 count"],
                "metadata": [:],
                "source": ["name": "iPhone", "bundleIdentifier": "com.apple.health"]
            ]
        ])

        XCTAssertTrue(gpxNames(entries).isEmpty)
        XCTAssertEqual(statistics.trackCount, 0)
        let readme = try readme(entries)
        XCTAssertTrue(readme.contains("No workout routes were found"))
        XCTAssertTrue(
            readme.contains("routes and nothing else"),
            "The archive has to say what it is, not just be nearly empty."
        )
    }

    func testARouteWhoseWorkoutIsUnknownIsStillExportedHonestly() throws {
        let id = "ffff0000-0000-4000-8000-000000000001"
        let (entries, statistics) = try build([
            header(route: id, unresolvedReason: "No workout claimed this route."),
            page(route: id, offset: 0, points: [location()]),
            end(route: id, total: 1)
        ])

        XCTAssertEqual(statistics.trackCount, 1)
        let name = try XCTUnwrap(gpxNames(entries).first)
        let root = try parse(entries, name)
        XCTAssertNil(
            root.first("trk")?.first("type"),
            "An activity Hozz could not establish must not be guessed at."
        )
        XCTAssertTrue(
            root.first("trk")?.first("name")?.text.contains("Workout route") ?? false
        )
    }

    // MARK: - File names

    func testFilesAreNamedByDateAndActivitySoTheySort() throws {
        let (entries, _) = try build(completeRoute())
        let name = try XCTUnwrap(gpxNames(entries).first)

        XCTAssertEqual(name, "Routes/2026-08-22-070000-running.gpx")
        XCTAssertTrue(name.hasSuffix(".gpx"))
    }

    func testTwoRoutesAtTheSameMomentDoNotOverwriteEachOther() throws {
        let first = "10000000-0000-4000-8000-000000000001"
        let second = "20000000-0000-4000-8000-000000000002"
        let (entries, statistics) = try build([
            workout(),
            header(route: first),
            page(route: first, offset: 0, points: [location()]),
            end(route: first, total: 1),
            header(route: second),
            page(route: second, offset: 0, points: [location(latitude: 51.7)]),
            end(route: second, total: 1)
        ])

        XCTAssertEqual(statistics.trackCount, 2)
        XCTAssertEqual(gpxNames(entries).count, 2, "One must not replace the other.")
    }

    func testAnActivityNameBecomesASafeFileName() {
        XCTAssertEqual(
            ExportGPXWriter.slug("High Intensity Interval Training"),
            "high-intensity-interval-training"
        )
        XCTAssertEqual(ExportGPXWriter.slug("Track and Field"), "track-and-field")
        XCTAssertEqual(ExportGPXWriter.slug("///"), "route")
    }

    // MARK: - Streaming

    /// The index holds where each page is, never the points in it, which is
    /// what keeps a long ride from being held whole in memory.
    func testTheIndexHoldsPositionsRatherThanPoints() throws {
        let id = "30000000-0000-4000-8000-000000000003"
        let source = directory.url.appending(path: "spool-index.ndjson")
        var data = Data()
        for line in [
            workout(),
            header(route: id),
            page(route: id, offset: 0, points: (0..<500).map { location(second: $0 % 60) }),
            page(route: id, offset: 500, points: (0..<500).map { location(second: $0 % 60) }),
            end(route: id, total: 1_000)
        ] {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: source)

        let index = try ExportGPXWriter.buildIndex(readingFrom: source)
        let route = try XCTUnwrap(index.routes.first)

        XCTAssertEqual(route.pages.count, 2)
        XCTAssertEqual(route.declaredCount, 1_000)
        XCTAssertEqual(route.pages[0]?.count, 500)
        XCTAssertGreaterThan(
            try XCTUnwrap(route.pages[500]?.byteOffset),
            try XCTUnwrap(route.pages[0]?.byteOffset),
            "A page is found by where it sits in the spool, not by being kept."
        )
    }

    // MARK: - The format itself

    func testGPXIsOfferedAndDescribedAccurately() {
        XCTAssertTrue(HealthExportFormat.allCases.contains(.gpx))
        XCTAssertEqual(HealthExportFormat.gpx.fileExtension, "zip")
        XCTAssertEqual(HealthExportFormat.gpx.displayName, "GPX")
        XCTAssertTrue(
            HealthExportFormat.gpx.coversRoutesOnly,
            "Picking this and getting an almost-empty archive is the failure to avoid."
        )
        XCTAssertTrue(HealthExportFormat.gpx.isLossy)
        for format in HealthExportFormat.allCases where format != .gpx {
            XCTAssertFalse(format.coversRoutesOnly)
        }
    }
}
