import Foundation
import HozzDeliver

/// What the GPX export produced, so the caller can say something true about it.
public struct ExportGPXStatistics: Equatable, Sendable {
    /// Files written. One per workout that had a usable route.
    public let trackCount: Int
    public let pointCount: Int
    /// Tracks with a gap in the middle or an unknown ending.
    public let incompleteTrackCount: Int
    /// Routes that reached the export with no usable points at all.
    public let emptyRouteCount: Int
    /// Points thrown away because their coordinates were not coordinates.
    public let droppedPointCount: Int

    public init(
        trackCount: Int,
        pointCount: Int,
        incompleteTrackCount: Int,
        emptyRouteCount: Int,
        droppedPointCount: Int
    ) {
        self.trackCount = trackCount
        self.pointCount = pointCount
        self.incompleteTrackCount = incompleteTrackCount
        self.emptyRouteCount = emptyRouteCount
        self.droppedPointCount = droppedPointCount
    }
}

/// Writes workout routes as GPX 1.1 tracks, one file per route.
///
/// GPX is the format every mapping and fitness tool reads, and it is the reason
/// a route is worth exporting at all — the same trace delivered as JSON is of no
/// use to someone moving their rides to something they host themselves.
///
/// **This format is a filter, not a projection.** A GPX file holds a track. It
/// has nowhere to put a heart rate, a sleep stage, or a body weight, so this
/// export contains only workouts that recorded GPS. That is stated in the
/// picker, in the archive's README, and in the statistics this returns, because
/// someone who chose it expecting a health export would otherwise get an
/// archive that looks broken.
///
/// **Incomplete routes are never presented as whole.** A route arrives as pages
/// addressed by absolute offset, and a sync that was interrupted can leave a
/// gap in the middle. A GPX that silently joins the two sides of that gap draws
/// a straight line across a mile of city and looks entirely correct, which is
/// worse than not existing. So a gap is expressed three ways: the track is
/// broken into a separate `<trkseg>` on each side of it, which is exactly what
/// a track segment means in GPX and what every renderer already honours; the
/// track's `<desc>` says how many points are missing; and the archive's README
/// lists every affected file.
enum ExportGPXWriter {
    struct Metadata {
        let runID: UUID
        let startedAt: Date
        let timeZone: TimeZone

        init(runID: UUID, startedAt: Date, timeZone: TimeZone = .current) {
            self.runID = runID
            self.startedAt = startedAt
            self.timeZone = timeZone
        }
    }

    /// The namespace the fields GPX has no element for are published under.
    ///
    /// Speed, course, and Core Location's accuracies do not exist in base GPX.
    /// They go in `<extensions>` under a declared namespace, because inventing
    /// bare elements in the GPX namespace produces a file that fails validation
    /// and that stricter parsers reject outright.
    static let extensionNamespace = "https://thatcube.github.io/hozz/gpx/1"
    static let extensionPrefix = "hozz"

    private static let pointsPerPage = WorkoutRouteEncoding.locationsPerRecord

    // MARK: - Writing

    @discardableResult
    static func write(
        readingFrom sourceURL: URL,
        into archive: ZipStreamWriter,
        metadata: Metadata
    ) throws -> ExportGPXStatistics {
        let index = try buildIndex(readingFrom: sourceURL)

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        var used: Set<String> = []
        var summaries: [TrackSummary] = []
        var statistics = Counters()

        for route in index.routes.sorted(by: { $0.order < $1.order }) {
            let plan = TrackPlan(route: route, pointsPerPage: pointsPerPage)
            guard !plan.segments.isEmpty else {
                statistics.emptyRoutes += 1
                summaries.append(
                    TrackSummary(
                        fileName: nil,
                        title: title(for: route, index: index, metadata: metadata),
                        pointCount: 0,
                        missingPointCount: plan.missingPointCount,
                        isComplete: false,
                        note: "No location pages reached this export."
                    )
                )
                continue
            }

            let name = uniqueFileName(
                for: route,
                index: index,
                metadata: metadata,
                used: &used
            )
            let written = try writeTrack(
                plan: plan,
                route: route,
                index: index,
                metadata: metadata,
                fileName: name,
                handle: handle,
                into: archive
            )

            statistics.points += written.pointCount
            statistics.dropped += written.droppedPointCount
            if written.pointCount == 0 {
                // Every page was present but held nothing usable. The file was
                // still written and says so; it is not a silent absence.
                statistics.emptyRoutes += 1
            } else {
                statistics.tracks += 1
            }
            if !plan.isComplete {
                statistics.incomplete += 1
            }
            summaries.append(
                TrackSummary(
                    fileName: name,
                    title: title(for: route, index: index, metadata: metadata),
                    pointCount: written.pointCount,
                    missingPointCount: plan.missingPointCount,
                    isComplete: plan.isComplete,
                    note: plan.note
                )
            )
        }

        try writeReadme(
            summaries: summaries,
            metadata: metadata,
            statistics: statistics,
            into: archive
        )

        return ExportGPXStatistics(
            trackCount: statistics.tracks,
            pointCount: statistics.points,
            incompleteTrackCount: statistics.incomplete,
            emptyRouteCount: statistics.emptyRoutes,
            droppedPointCount: statistics.dropped
        )
    }

    private struct Counters {
        var tracks = 0
        var points = 0
        var incomplete = 0
        var emptyRoutes = 0
        var dropped = 0
    }

    private struct WrittenTrack {
        let pointCount: Int
        let droppedPointCount: Int
    }

    private static func writeTrack(
        plan: TrackPlan,
        route: RouteIndex,
        index: SpoolIndex,
        metadata: Metadata,
        fileName: String,
        handle: FileHandle,
        into archive: ZipStreamWriter
    ) throws -> WrittenTrack {
        try archive.beginEntry(name: fileName)

        let workout = route.workoutID.flatMap { index.workouts[$0] }
        let started = route.startDate ?? workout?.startDate
        let title = title(for: route, index: index, metadata: metadata)
        let description = describe(plan: plan, route: route, workout: workout)

        try archive.write(
            Data(
                header(
                    title: title,
                    description: description,
                    time: started
                ).utf8
            )
        )

        try archive.write(Data("  <trk>\n".utf8))
        try archive.write(Data("    <name>\(escaped(title))</name>\n".utf8))
        try archive.write(Data("    <desc>\(escaped(description))</desc>\n".utf8))
        if let activity = route.activityType.flatMap(WorkoutActivityNames.name(for:)) {
            try archive.write(Data("    <type>\(escaped(activity))</type>\n".utf8))
        }

        var points = 0
        var dropped = 0
        for segment in plan.segments {
            try archive.write(Data("    <trkseg>\n".utf8))
            for page in segment {
                // One page in memory at a time. A long ride is hundreds of
                // thousands of points and must never be held whole.
                let locations = try locations(at: page.byteOffset, handle: handle)
                for location in locations {
                    guard let element = point(from: location) else {
                        dropped += 1
                        continue
                    }
                    try archive.write(Data(element.utf8))
                    points += 1
                }
            }
            try archive.write(Data("    </trkseg>\n".utf8))
        }

        try archive.write(Data("  </trk>\n</gpx>\n".utf8))
        try archive.endEntry()
        return WrittenTrack(pointCount: points, droppedPointCount: dropped)
    }

    // MARK: - GPX

    private static func header(
        title: String,
        description: String,
        time: Date?
    ) -> String {
        var text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Hozz"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:\(extensionPrefix)="\(extensionNamespace)"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 \
        http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escaped(title))</name>
            <desc>\(escaped(description))</desc>

        """
        // GPX 1.1 fixes the order of a metadata's children: name, desc, then
        // time. Out of order is a file that fails validation.
        if let time {
            text += "    <time>\(timestamp(time))</time>\n"
        }
        text += "  </metadata>\n"
        return text
    }

    /// One `<trkpt>`.
    ///
    /// Returns nil for a point that is not a point. A latitude of `NaN` or a
    /// longitude past 180 is not something a consumer can plot, and writing it
    /// produces a file that fails validation and takes every other track in the
    /// archive down with it in a strict importer.
    static func point(from location: [String: Any]) -> String? {
        guard
            let latitude = double(location["latitude"]),
            let longitude = double(location["longitude"]),
            latitude.isFinite, longitude.isFinite,
            (-90...90).contains(latitude),
            (-180...180).contains(longitude)
        else {
            return nil
        }

        var text = "      <trkpt lat=\"\(decimal(latitude, places: 7))\""
        text += " lon=\"\(decimal(longitude, places: 7))\">\n"
        if let altitude = double(location["altitude"]), altitude.isFinite {
            text += "        <ele>\(decimal(altitude, places: 3))</ele>\n"
        }
        if let time = location["timestamp"] as? String, !time.isEmpty {
            text += "        <time>\(escaped(time))</time>\n"
        }

        // Speed, course, and Core Location's accuracies have no element in base
        // GPX. They are published under Hozz's own namespace rather than
        // invented as bare elements, which would make the file invalid.
        var extensions = ""
        for key in ["speed", "course", "horizontalAccuracy", "verticalAccuracy", "speedAccuracy", "courseAccuracy"] {
            guard let value = double(location[key]), value.isFinite else {
                continue
            }
            extensions += "            <\(extensionPrefix):\(key)>"
                + decimal(value, places: 3)
                + "</\(extensionPrefix):\(key)>\n"
        }
        if !extensions.isEmpty {
            text += "        <extensions>\n\(extensions)        </extensions>\n"
        }
        text += "      </trkpt>\n"
        return text
    }

    /// XML has no escape for most control characters, so they are removed
    /// rather than encoded. A source name carrying one would otherwise produce
    /// a file no parser will open.
    static func escaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value.unicodeScalars {
            switch character {
            case "&":
                result += "&amp;"
            case "<":
                result += "&lt;"
            case ">":
                result += "&gt;"
            case "\"":
                result += "&quot;"
            case "'":
                result += "&apos;"
            case "\u{09}", "\u{0A}", "\u{0D}":
                result.unicodeScalars.append(character)
            default:
                if character.value < 0x20 || (0x7F...0x9F).contains(character.value) {
                    continue
                }
                result.unicodeScalars.append(character)
            }
        }
        return result
    }

    /// A fixed-point decimal that does not change with the phone's language.
    ///
    /// A device set to a locale using a comma for a decimal separator would
    /// otherwise write `lat="51,5007"`, which is not a number in XML.
    static func decimal(_ value: Double, places: Int) -> String {
        guard value.isFinite else {
            return "0"
        }
        var text = String(format: "%.\(places)f", locale: posix, value)
        if text.contains(".") {
            while text.hasSuffix("0") {
                text.removeLast()
            }
            if text.hasSuffix(".") {
                text.removeLast()
            }
        }
        return text.isEmpty || text == "-0" ? "0" : text
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }

    // MARK: - Naming

    static func title(
        for route: RouteIndex,
        index: SpoolIndex,
        metadata: Metadata
    ) -> String {
        let workout = route.workoutID.flatMap { index.workouts[$0] }
        let activity = route.activityType.flatMap(WorkoutActivityNames.name(for:))
        let started = route.startDate ?? workout?.startDate
        let day = started.map { localDay($0, in: metadata.timeZone) } ?? "Undated"
        return "\(activity ?? "Workout route") — \(day)"
    }

    private static func uniqueFileName(
        for route: RouteIndex,
        index: SpoolIndex,
        metadata: Metadata,
        used: inout Set<String>
    ) -> String {
        let workout = route.workoutID.flatMap { index.workouts[$0] }
        let started = route.startDate ?? workout?.startDate
        let stamp = started.map { localStamp($0, in: metadata.timeZone) } ?? "undated"
        let activity = route.activityType
            .flatMap(WorkoutActivityNames.name(for:))
            .map(slug) ?? "route"

        var base = "\(stamp)-\(activity)"
        var candidate = base
        var suffix = 2
        // Two routes can share a second — a workout can carry more than one.
        // A numbered name is the same answer the CSV export gives a type that
        // reappears, and it beats one file silently replacing another.
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        base = candidate
        used.insert(base)
        return "Routes/\(base).gpx"
    }

    static func slug(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !result.isEmpty {
                    result.append("-")
                }
                pendingSeparator = false
                result.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return result.isEmpty ? "route" : result
    }

    static func localDay(_ date: Date, in timeZone: TimeZone) -> String {
        let shifted = date.addingTimeInterval(
            Double(timeZone.secondsFromGMT(for: date))
        )
        return String(
            Date.ISO8601FormatStyle(timeZone: .gmt).format(shifted).prefix(10)
        )
    }

    private static func localStamp(_ date: Date, in timeZone: TimeZone) -> String {
        let shifted = date.addingTimeInterval(
            Double(timeZone.secondsFromGMT(for: date))
        )
        let iso = Date.ISO8601FormatStyle(timeZone: .gmt).format(shifted)
        // 2026-08-22T07:00:00Z becomes 2026-08-22-070000, which sorts.
        let day = iso.prefix(10)
        let time = iso.dropFirst(11).prefix(8).replacingOccurrences(of: ":", with: "")
        return "\(day)-\(time)"
    }

    // MARK: - Describing what is missing

    private static func describe(
        plan: TrackPlan,
        route: RouteIndex,
        workout: WorkoutFacts?
    ) -> String {
        var parts: [String] = []
        if let activity = route.activityType.flatMap(WorkoutActivityNames.name(for:)) {
            parts.append(activity)
        }
        if let duration = workout?.duration ?? route.duration {
            parts.append("\(durationText(duration)) long")
        }
        if let source = route.sourceName ?? workout?.sourceName {
            parts.append("recorded by \(source)")
        }
        parts.append("exported by Hozz")

        var text = parts.joined(separator: ", ") + "."
        if let note = plan.note {
            text += " " + note
        }
        return text
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(total)s"
    }

    // MARK: - README

    private static func writeReadme(
        summaries: [TrackSummary],
        metadata: Metadata,
        statistics: Counters,
        into archive: ZipStreamWriter
    ) throws {
        var text = "# Workout routes\n\n"
        text += "GPX 1.1 tracks exported by Hozz on "
        text += "\(localDay(metadata.startedAt, in: metadata.timeZone)) "
        text += "(\(metadata.timeZone.identifier)).\n\n"

        text += "**This archive holds routes and nothing else.** A GPX file is a "
        text += "track; it has nowhere to put a heart rate, a sleep stage, or a "
        text += "weight. Workouts recorded without GPS — a treadmill run, a gym "
        text += "session — have no route, and produce no file here. That is not "
        text += "a failure, and it is not everything Hozz can export: choose "
        text += "NDJSON or SQLite for a full export.\n\n"

        if summaries.isEmpty {
            text += "No workout routes were found in this export.\n"
            try archive.beginEntry(name: "README.md")
            try archive.write(Data(text.utf8))
            try archive.endEntry()
            return
        }

        text += "## Tracks\n\n"
        text += "| File | Track | Points | Complete |\n| --- | --- | --- | --- |\n"
        for summary in summaries {
            let file = summary.fileName.map { "`\($0)`" } ?? "*(no file)*"
            let complete = summary.isComplete ? "Yes" : "**No**"
            text += "| \(file) | \(summary.title) | \(summary.pointCount) | \(complete) |\n"
        }
        text += "\n"

        let incomplete = summaries.filter { !$0.isComplete }
        if incomplete.isEmpty {
            text += "Every track above is complete: each one runs from its first "
            text += "recorded point to its last with nothing missing in between.\n"
        } else {
            text += "## Incomplete tracks\n\n"
            text += "A route travels in pages, and a sync that was interrupted "
            text += "can leave one out. Where that happened, the track is split "
            text += "into a separate `<trkseg>` on each side of the gap rather "
            text += "than drawn straight across it — a GPX that joins the two "
            text += "sides looks completely correct and is not.\n\n"
            for summary in incomplete {
                let file = summary.fileName.map { "`\($0)`" } ?? "*(no file written)*"
                text += "- \(file) — \(summary.note ?? "incomplete")\n"
            }
            text += "\nRe-running the export picks up whatever has since arrived.\n"
        }

        if statistics.dropped > 0 {
            text += "\n\(statistics.dropped) point"
            text += statistics.dropped == 1 ? " was" : "s were"
            text += " left out because the coordinates were not usable.\n"
        }

        try archive.beginEntry(name: "README.md")
        try archive.write(Data(text.utf8))
        try archive.endEntry()
    }

    private struct TrackSummary {
        let fileName: String?
        let title: String
        let pointCount: Int
        let missingPointCount: Int
        let isComplete: Bool
        let note: String?
    }

    // MARK: - Reading a page back

    private static func locations(
        at byteOffset: UInt64,
        handle: FileHandle
    ) throws -> [[String: Any]] {
        try handle.seek(toOffset: byteOffset)
        var buffer = Data()
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                buffer = buffer.subdata(in: buffer.startIndex..<index)
                break
            }
            let chunk = try handle.read(upToCount: 256 * 1_024) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }
        guard
            !buffer.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: buffer)
                as? [String: Any],
            let locations = object[WorkoutRouteEncoding.shape.elementsKey]
                as? [[String: Any]]
        else {
            return []
        }
        return locations
    }
}
