import Foundation

/// Where one page of a route's points sits in the spool.
struct RoutePageRef: Equatable, Sendable {
    let byteOffset: UInt64
    let count: Int
}

/// What one workout contributes to a track's description.
struct WorkoutFacts: Equatable, Sendable {
    let activityType: Int?
    let duration: Double?
    let startDate: Date?
    let endDate: Date?
    let sourceName: String?
}

/// Everything known about one route, gathered in a single pass.
struct RouteIndex: Sendable {
    let id: String
    /// First-seen position, so the archive's order matches the export's.
    let order: Int
    var startDate: Date?
    var endDate: Date?
    var workoutID: String?
    var activityType: Int?
    var sourceName: String?
    var unresolvedReason: String?
    /// Absolute point offset to the page holding it. A dictionary because a
    /// replayed page repeats an offset, and a repeat is the same bytes.
    var pages: [Int: RoutePageRef] = [:]
    /// The total the end marker claimed, when one arrived.
    var declaredCount: Int?

    var duration: Double? {
        guard let startDate, let endDate else {
            return nil
        }
        let seconds = endDate.timeIntervalSince(startDate)
        return seconds > 0 ? seconds : nil
    }
}

struct SpoolIndex: Sendable {
    var routes: [RouteIndex] = []
    var workouts: [String: WorkoutFacts] = [:]
}

/// How a route's pages become track segments.
///
/// A route is written as pages at fixed absolute offsets — 0, 500, 1000 — so a
/// missing page is not a shorter list, it is a hole with a known size. That is
/// what makes it possible to be honest about a gap instead of quietly closing
/// it: the pages either side are known, and so is how many points fell out
/// between them.
struct TrackPlan {
    /// Contiguous runs of pages. One `<trkseg>` each.
    let segments: [[RoutePageRef]]
    let missingPointCount: Int
    let isComplete: Bool
    /// Plain-language description of what is missing, if anything.
    let note: String?

    init(route: RouteIndex, pointsPerPage: Int) {
        let offsets = route.pages.keys.sorted()
        var segments: [[RoutePageRef]] = []
        var current: [RoutePageRef] = []
        var missing = 0
        var gapCount = 0
        var expected: Int?

        for offset in offsets {
            guard let page = route.pages[offset] else {
                continue
            }
            if let expected, offset != expected {
                // A hole. The pages either side stay in separate segments so
                // nothing draws a line across it.
                missing += max(0, offset - expected)
                gapCount += 1
                segments.append(current)
                current = []
            }
            current.append(page)
            expected = offset + max(page.count, 1)
        }
        if !current.isEmpty {
            segments.append(current)
        }

        // A route whose first page never arrived is missing its beginning, and
        // a track that starts mid-ride must not look like one that started
        // where the ride did.
        var missingStart = 0
        if let first = offsets.first, first > 0 {
            missingStart = first
            missing += first
        }

        let present = route.pages.values.reduce(0) { $0 + $1.count }
        var missingEnd = 0
        if let declared = route.declaredCount {
            missingEnd = max(0, declared - present - missing)
            missing += missingEnd
        }

        self.segments = segments
        missingPointCount = missing
        // Without an end marker the export never learned how long the route
        // was, so the tail cannot be vouched for either way.
        let knowsTheEnd = route.declaredCount != nil
        isComplete = missing == 0 && gapCount == 0 && knowsTheEnd && !segments.isEmpty

        if segments.isEmpty {
            note = "No location pages for this route reached the export, so no track could be written."
        } else if !knowsTheEnd {
            note = missing > 0
                ? "Incomplete: \(missing) point\(missing == 1 ? "" : "s") are missing, and the export never recorded where this route ended, so it may also stop early."
                : "The export never recorded where this route ended, so it may stop before the ride did."
        } else if missing > 0 {
            var reasons: [String] = []
            if missingStart > 0 {
                reasons.append("\(missingStart) at the start")
            }
            if gapCount > 0 {
                reasons.append(
                    "\(gapCount) gap\(gapCount == 1 ? "" : "s") in the middle"
                )
            }
            if missingEnd > 0 {
                reasons.append("\(missingEnd) at the end")
            }
            note = "Incomplete: \(missing) of \(missing + present) point"
                + (missing + present == 1 ? "" : "s")
                + " are missing (\(reasons.joined(separator: ", ")))."
                + " Each run of recorded points is its own track segment, so nothing is drawn across a gap."
        } else {
            note = nil
        }
    }
}

extension ExportGPXWriter {
    /// One pass over the spool, collecting where everything is.
    ///
    /// Only positions and counts are kept, never the points themselves — a few
    /// dozen bytes per page, so a year of rides costs a fraction of a megabyte
    /// and the points are read back one page at a time afterwards.
    static func buildIndex(readingFrom sourceURL: URL) throws -> SpoolIndex {
        var reader = try IndexedLineReader(fileURL: sourceURL)
        defer { reader.close() }

        let shape = WorkoutRouteEncoding.shape
        var index = SpoolIndex()
        var positions: [String: Int] = [:]

        while let entry = try reader.nextLine() {
            guard
                let object = try? JSONSerialization.jsonObject(with: entry.line)
                    as? [String: Any],
                let kind = object["kind"] as? String
            else {
                continue
            }

            switch kind {
            case "workout":
                if let id = object["id"] as? String {
                    index.workouts[id] = WorkoutFacts(
                        activityType: integer(object["activityType"]),
                        duration: number(object["duration"]),
                        startDate: date(object["startDate"]),
                        endDate: date(object["endDate"]),
                        sourceName: (object["source"] as? [String: Any])?["name"] as? String
                    )
                }

            case shape.headerKind:
                guard let id = object["id"] as? String else {
                    continue
                }
                let position = position(of: id, in: &index, positions: &positions)
                index.routes[position].startDate = date(object["startDate"])
                index.routes[position].endDate = date(object["endDate"])
                index.routes[position].sourceName =
                    (object["source"] as? [String: Any])?["name"] as? String
                if let workout = object["workout"] as? [String: Any] {
                    if workout["state"] as? String == "resolved" {
                        index.routes[position].workoutID = workout["id"] as? String
                        index.routes[position].activityType =
                            integer(workout["activityType"])
                    } else {
                        index.routes[position].unresolvedReason =
                            workout["reason"] as? String
                    }
                }

            case shape.elementKind:
                guard
                    let sample = object["sample"] as? String,
                    let offset = integer(object["offset"])
                else {
                    continue
                }
                let position = position(of: sample, in: &index, positions: &positions)
                let count = integer(object["count"])
                    ?? (object[shape.elementsKey] as? [Any])?.count
                    ?? 0
                // A replayed page carries the same offset and the same bytes,
                // so keeping one of them is not a choice between two answers.
                index.routes[position].pages[offset] = RoutePageRef(
                    byteOffset: entry.byteOffset,
                    count: count
                )

            case shape.endKind:
                guard let sample = object["sample"] as? String else {
                    continue
                }
                let position = position(of: sample, in: &index, positions: &positions)
                index.routes[position].declaredCount = integer(object[shape.elementsKey])

            default:
                continue
            }
        }

        return index
    }

    private static func position(
        of id: String,
        in index: inout SpoolIndex,
        positions: inout [String: Int]
    ) -> Int {
        if let existing = positions[id] {
            return existing
        }
        let position = index.routes.count
        index.routes.append(RouteIndex(id: id, order: position))
        positions[id] = position
        return position
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        number(_: value).map { Int($0) }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else {
            return nil
        }
        if let parsed = try? Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).parse(text) {
            return parsed
        }
        return try? Date.ISO8601FormatStyle(timeZone: .gmt).parse(text)
    }
}

/// An NDJSON reader that also says where each line started.
///
/// The byte offset is what lets the points be read back a page at a time in
/// whatever order the route needs, instead of buffering a whole ride to sort
/// it. Pages usually arrive in order and this costs nothing; when they do not,
/// it is the difference between a correct track and one that needed hundreds of
/// megabytes of memory to produce.
struct IndexedLineReader {
    struct Entry {
        let line: Data
        let byteOffset: UInt64
    }

    private let handle: FileHandle
    private let bufferSize: Int
    private var buffer = Data()
    private var isAtEnd = false
    /// Where the unread remainder of the file begins.
    private var cursor: UInt64 = 0

    init(fileURL: URL, bufferSize: Int = 1 * 1_024 * 1_024) throws {
        handle = try FileHandle(forReadingFrom: fileURL)
        self.bufferSize = bufferSize
    }

    mutating func nextLine() throws -> Entry? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<index)
                buffer = buffer.subdata(in: (index + 1)..<buffer.endIndex)
                let start = cursor
                cursor += UInt64(line.count) + 1
                if line.isEmpty {
                    continue
                }
                return Entry(line: line, byteOffset: start)
            }
            guard !isAtEnd else {
                guard !buffer.isEmpty else {
                    return nil
                }
                let line = buffer
                buffer = Data()
                let start = cursor
                cursor += UInt64(line.count)
                return line.isEmpty ? nil : Entry(line: line, byteOffset: start)
            }

            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty {
                isAtEnd = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func close() {
        try? handle.close()
    }
}
