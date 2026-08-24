import Foundation
import HozzCatalog

/// What the pass produced, and what it had to hold to produce it.
struct ExportMarkdownStatistics: Equatable {
    var linesRead = 0
    var notesWritten = 0
    var samplesSummarised = 0
    var workoutsSummarised = 0
    var deletionsSeen = 0
    /// Objects Health returned that Hozz could not encode. They carry no
    /// values, so a summary has nothing to say about them beyond that they
    /// happened.
    var encodingIssues = 0
    var undatedRecords = 0
    var unreadableLines = 0
    /// Pages of series detail — a route's points, a recording's voltages, a
    /// quantity series' readings — kept out of the day totals.
    ///
    /// A daily note answers "how much did I record that day", and a page is
    /// not a measurement: counting the four pages a heart-rate series arrives
    /// in as four heart-rate readings would inflate the day by exactly the
    /// amount of detail Hozz got better at exporting, which is the wrong
    /// direction for a number to move.
    var seriesPagesSkipped = 0
    /// Days the pass was holding a summary for. This grows with how much
    /// calendar an export covers, never with how many records it contains,
    /// which is the whole claim that this streams.
    var retainedDays = 0
    /// Per-day, per-type totals held at once. Bounded by days times the number
    /// of Health types, for the same reason.
    var retainedTotals = 0
}

/// Writes one Markdown note per day, for people who keep a journal.
///
/// ## This one is lossy, loudly
///
/// A daily note is a *summary*: 812 heart-rate readings become an average, a
/// low and a high, and the readings themselves are gone. Metadata, device
/// details, sources, sample identifiers and deletions have nowhere to go in
/// prose. That is the point of the format and it is also its cost, so the
/// export says so in the picker, in a note at the root of the archive, and at
/// the foot of every single day.
///
/// ## Why it can stream anyway
///
/// Records arrive grouped by type rather than by day, so a day's note cannot be
/// written until the whole export has been read. What is held between the two
/// is one small summary per day — counts, totals, extremes — never the records
/// themselves. Memory therefore tracks how many days an export covers, not how
/// many records it holds: a decade of history is a few thousand summaries
/// whether it contains ten thousand records or ten million.
///
/// ## Days, and which one a night belongs to
///
/// Days are the ones the phone lived in, not UTC days. Everything is filed
/// under the local day it started — except sleep, which is filed under the day
/// it *ended*, because "last night's sleep" belongs to the morning you woke up
/// and not to two notes either side of midnight.
///
/// Sleep is also the one thing not totalled a record at a time. Health returns
/// overlapping records for one night, so their durations are merged before
/// anything is filed — which means holding the date pairs, and only those, for
/// the length of the read. A decade of nights is on the order of tens of
/// thousands of pairs against an export that may hold millions of records.
enum ExportMarkdownWriter {
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

    /// Workouts listed in full on one note before the rest are counted rather
    /// than named. A day with more than this is a data-logging accident, and
    /// the note stays readable instead of becoming the dump it is not meant to
    /// be.
    static let workoutDetailLimit = 25

    @discardableResult
    static func write(
        readingFrom sourceURL: URL,
        into archive: ZipStreamWriter,
        metadata: Metadata
    ) throws -> ExportMarkdownStatistics {
        var statistics = ExportMarkdownStatistics()
        var days: [Int: DaySummary] = [:]
        var types = TypeTable()
        let day = LocalDayFormatter(timeZone: metadata.timeZone)
        var runRecords: [Data] = []
        var coverage: [TypeCoverage] = []

        var reader = try NDJSONLineReader(fileURL: sourceURL)
        defer { reader.close() }

        // Sleep is the one thing that cannot be totalled a record at a time.
        // Health returns overlapping records — a watch, a phone and a sleep app
        // all describing one night — and adding their durations reports eleven
        // hours for a seven-hour night. They have to be merged, and merging has
        // to happen across the whole set before anything is filed under a day,
        // because two records of one night can end either side of midnight and
        // would never meet if each day were merged separately.
        //
        // This is the one exception to holding no records: these are date pairs
        // rather than records, and only for sleep. A decade of nights is on the
        // order of tens of thousands of them, a megabyte or so, against an
        // export that may hold millions of records of every other kind.
        var asleepStretches: [DateInterval] = []
        var inBedStretches: [DateInterval] = []

        while let line = try reader.nextLine() {
            statistics.linesRead += 1

            guard let record = ExportRecord(line: line) else {
                statistics.unreadableLines += 1
                continue
            }

            if record.isRunRecord {
                runRecords.append(line)
                if record.kind == "typeSummary" || record.kind == "typeError" {
                    coverage.append(TypeCoverage(record))
                }
                continue
            }
            if record.kind == "characteristic" || record.kind == "characteristics" {
                // Date of birth and blood type are true of a person, not of a
                // Tuesday. There is no day to file them under and no summary
                // to make of them, so they travel in the export log instead of
                // being counted as records that happened to lack a date.
                runRecords.append(line)
                continue
            }
            if record.kind == "sampleEncodingError" {
                // An object Health returned that Hozz could not encode. It has
                // no values to summarise, so it travels in the export log and
                // is reported as itself rather than counted as a record that
                // happened to have no date.
                runRecords.append(line)
                statistics.encodingIssues += 1
                continue
            }
            if record.kind == "deletion" {
                // A deletion has no date, so there is no day to file it under.
                // It is counted and reported rather than pretended away.
                statistics.deletionsSeen += 1
                runRecords.append(line)
                continue
            }
            if Self.isSeriesDetail(record.kind) {
                // The elements of a series carry the type identifier of the
                // sample they belong to and a date range inside it, so without
                // this they would be summarised as if each page were a reading
                // of that type. A day with one cycling power series would
                // report several hundred "power readings" that are really the
                // pages one reading arrived in. The detail itself belongs in
                // the lossless formats; a daily note keeps the aggregate,
                // which is the one number a day has an answer for.
                statistics.seriesPagesSkipped += 1
                continue
            }

            // Sleep is filed under the morning it ended; everything else under
            // the moment it started.
            let isSleep = record.type == sleepAnalysis
            guard let anchor = isSleep
                ? (record.endDate ?? record.startDate)
                : record.startDate
            else {
                statistics.undatedRecords += 1
                continue
            }

            let typeID = record.type.map { types.identifier(for: $0) }
            let dayNumber = day.dayNumber(for: anchor)
            // Subscripting with a default mutates the stored value in place. A
            // read-modify-write through a local copy would instead duplicate
            // the day's totals on every single record.
            days[dayNumber, default: DaySummary()].absorb(
                record,
                typeID: typeID,
                isSleep: isSleep,
                timeZone: metadata.timeZone
            )

            if isSleep,
               let start = record.startDate,
               let end = record.endDate,
               end > start,
               let value = record.value.map({ Int($0) }) {
                let stretch = DateInterval(start: start, end: end)
                if SleepIntervals.isAsleep(value) {
                    asleepStretches.append(stretch)
                } else if SleepIntervals.isInBed(value) {
                    inBedStretches.append(stretch)
                }
            }

            if record.kind == "workout" {
                statistics.workoutsSummarised += 1
            } else {
                statistics.samplesSummarised += 1
            }
        }

        // Now that every record has been seen, the night can be worked out. A
        // stretch is filed under the local day it ended on — the day the
        // sleeper woke up — which is the rule the chart follows too.
        for (dayNumber, seconds) in SleepIntervals.secondsByDay(
            asleepStretches,
            dayNumber: { day.dayNumber(for: $0) }
        ) {
            days[dayNumber, default: DaySummary()].asleepSeconds += seconds
        }
        for (dayNumber, seconds) in SleepIntervals.secondsByDay(
            inBedStretches,
            dayNumber: { day.dayNumber(for: $0) }
        ) {
            days[dayNumber, default: DaySummary()].inBedSeconds += seconds
        }

        statistics.retainedDays = days.count
        statistics.retainedTotals = days.values.reduce(0) { $0 + $1.totals.count }

        try writeReadme(
            into: archive,
            metadata: metadata,
            statistics: statistics,
            days: days,
            coverage: coverage
        )

        for dayNumber in days.keys.sorted() {
            guard let summary = days[dayNumber] else {
                continue
            }
            let name = LocalDayFormatter.text(forDayNumber: dayNumber)
            try archive.beginEntry(name: "Daily/\(name).md")
            try archive.write(
                Data(
                    note(
                        dayNumber: dayNumber,
                        summary: summary,
                        types: types,
                        metadata: metadata
                    ).utf8
                )
            )
            try archive.endEntry()
            statistics.notesWritten += 1
        }

        // The run's own records go along verbatim, the same way the CSV export
        // carries them, so what the summary leaves out is still in the archive.
        try archive.beginEntry(name: "export-log.ndjson")
        for record in runRecords {
            try archive.write(record)
            try archive.write(Data([0x0A]))
        }
        try archive.endEntry()

        return statistics
    }

    // MARK: - The notes

    private static func note(
        dayNumber: Int,
        summary: DaySummary,
        types: TypeTable,
        metadata: Metadata
    ) -> String {
        let date = LocalDayFormatter.text(forDayNumber: dayNumber)
        let civil = LocalDayFormatter.civilFromDays(dayNumber)
        let weekday = Self.weekday(dayNumber)

        var text = "---\n"
        for (key, value) in frontMatter(
            date: date,
            weekday: weekday,
            summary: summary,
            types: types,
            metadata: metadata
        ) {
            text += "\(key): \(value)\n"
        }
        text += "---\n\n"

        text += "# \(weekday), \(civil.day) \(Self.month(civil.month)) \(civil.year)\n\n"
        text += headline(summary: summary, types: types) + "\n\n"

        if !summary.workouts.isEmpty {
            text += "## Workouts\n\n"
            text += "| Started | Activity | Duration |\n| --- | --- | --- |\n"
            for workout in summary.workouts {
                text += "| \(workout.startTime) | \(escape(workout.activity)) "
                text += "| \(duration(workout.seconds)) |\n"
            }
            if summary.workoutCount > summary.workouts.count {
                let extra = summary.workoutCount - summary.workouts.count
                text += "\n\(extra) further "
                text += extra == 1 ? "workout is" : "workouts are"
                text += " counted above but not listed.\n"
            }
            text += "\n"
        }

        if summary.sleepSegments > 0 {
            text += "## Sleep\n\n"
            var parts: [String] = []
            if summary.asleepSeconds > 0 {
                parts.append("asleep for \(duration(summary.asleepSeconds))")
            }
            if summary.inBedSeconds > 0 {
                parts.append("in bed for \(duration(summary.inBedSeconds))")
            }
            if parts.isEmpty {
                parts.append("\(summary.sleepSegments) sleep records")
            }
            text += parts.joined(separator: ", ").capitalisedFirst
            text += ", from \(summary.sleepSegments) "
            text += summary.sleepSegments == 1 ? "segment" : "segments"
            text += ". Sleep is filed under the day you woke up.\n\n"
        }

        text += "## Everything recorded\n\n"
        text += "| Type | Records | Total | Average | Low | High | Unit |\n"
        text += "| --- | --- | --- | --- | --- | --- | --- |\n"
        let rows = summary.totals
            .map { (types.name(for: $0.key), $0.value, types.isAveraged($0.key)) }
            .sorted { $0.0 < $1.0 }
        for (name, totals, isAveraged) in rows {
            text += "| \(escape(name)) | \(grouped(Double(totals.count))) | "
            if totals.valueCount > 0 {
                // A total of heart rates is arithmetic nobody wants, so a type
                // that is measured rather than accumulated leaves it blank
                // instead of publishing a number that reads like a finding.
                text += isAveraged ? " | " : "\(grouped(totals.sum)) | "
                text += "\(grouped(totals.average)) | "
                text += "\(grouped(totals.minimum)) | \(grouped(totals.maximum)) | "
            } else {
                text += " |  |  |  | "
            }
            text += "\(escape(totals.unit ?? "")) |\n"
        }
        if rows.isEmpty {
            text += "| — | 0 |  |  |  |  |  |\n"
        }

        text += "\n---\n\n"
        text += "*A summary written by Hozz on "
        text += "\(shortTimestamp(metadata.startedAt, in: metadata.timeZone)). "
        text += "It keeps totals, not records: the "
        text += "\(grouped(Double(summary.recordCount))) "
        text += summary.recordCount == 1 ? "record" : "records"
        text += " behind these numbers, and everything Health stored alongside "
        text += "them, are only in the NDJSON, JSON, or SQLite exports.*\n"
        return text
    }

    /// Numbers Obsidian's Dataview can query, named so the key says its unit.
    private static func frontMatter(
        date: String,
        weekday: String,
        summary: DaySummary,
        types: TypeTable,
        metadata: Metadata
    ) -> [(String, String)] {
        var entries: [(String, String)] = [
            ("date", date),
            ("weekday", quoted(weekday)),
            ("time_zone", quoted(metadata.timeZone.identifier)),
            ("generated_by", quoted("Hozz")),
            ("lossy", "true")
        ]

        for highlight in highlights {
            guard
                let typeID = types.existingIdentifier(for: highlight.identifier),
                let totals = summary.totals[typeID],
                totals.valueCount > 0
            else {
                continue
            }
            let value = highlight.aggregation == .total
                ? totals.sum
                : totals.average
            entries.append(
                (
                    key(highlight.key, unit: totals.unit),
                    plain(value)
                )
            )
        }

        if summary.asleepSeconds > 0 {
            entries.append(("sleep_hours", plain(summary.asleepSeconds / 3_600)))
        }
        if summary.inBedSeconds > 0 {
            entries.append(("in_bed_hours", plain(summary.inBedSeconds / 3_600)))
        }
        if summary.workoutCount > 0 {
            entries.append(("workouts", String(summary.workoutCount)))
            entries.append(
                ("workout_minutes", plain(summary.workoutSeconds / 60))
            )
        }
        entries.append(("records", String(summary.recordCount)))
        entries.append(("health_types", String(summary.totals.count)))
        return entries
    }

    private static func headline(
        summary: DaySummary,
        types: TypeTable
    ) -> String {
        var sentences: [String] = []
        var opening: [String] = []

        if let steps = summary.total(of: stepCount, in: types) {
            opening.append("**\(grouped(steps)) steps**")
        }
        if let distance = summary.entry(for: distanceWalkingRunning, in: types),
           let text = distanceText(distance) {
            opening.append(text)
        }
        if let energy = summary.total(of: activeEnergy, in: types) {
            opening.append("**\(grouped(energy)) kcal** of active energy")
        }
        if !opening.isEmpty {
            sentences.append(list(opening).capitalisedFirst + ".")
        }

        if summary.asleepSeconds > 0 {
            sentences.append("Asleep for **\(duration(summary.asleepSeconds))**.")
        }
        if summary.workoutCount > 0 {
            var sentence = "\(summary.workoutCount) "
            sentence += summary.workoutCount == 1 ? "workout" : "workouts"
            if summary.workoutSeconds > 0 {
                sentence += " totalling **\(duration(summary.workoutSeconds))**"
            }
            sentences.append(sentence + ".")
        }
        if let resting = summary.average(of: restingHeartRate, in: types) {
            sentences.append(
                "Resting heart rate **\(grouped(resting)) bpm**."
            )
        }

        if sentences.isEmpty {
            let count = summary.recordCount
            return "\(grouped(Double(count))) "
                + (count == 1 ? "record" : "records")
                + " across \(summary.totals.count) "
                + (summary.totals.count == 1 ? "type" : "types")
                + "."
        }
        return sentences.joined(separator: " ")
    }

    private static func writeReadme(
        into archive: ZipStreamWriter,
        metadata: Metadata,
        statistics: ExportMarkdownStatistics,
        days: [Int: DaySummary],
        coverage: [TypeCoverage]
    ) throws {
        let sorted = days.keys.sorted()
        var text = "# Your Health data, one note per day\n\n"
        text += "Exported by [Hozz](https://github.com/thatcube/hozz) on "
        text += "\(shortTimestamp(metadata.startedAt, in: metadata.timeZone)).\n\n"

        if let first = sorted.first, let last = sorted.last {
            text += "There are \(days.count) "
            text += days.count == 1 ? "note" : "notes"
            text += " in `Daily/`, covering "
            text += "\(LocalDayFormatter.text(forDayNumber: first)) to "
            text += "\(LocalDayFormatter.text(forDayNumber: last)).\n\n"
        } else {
            text += "There are no daily notes, because this export contained "
            text += "no dated records.\n\n"
        }

        text += "## This export is a summary, not your data\n\n"
        text += "Every note keeps counts, totals and extremes. It does not keep "
        text += "the individual records behind them, and it has nowhere to put "
        text += "sample identifiers, metadata, sources, devices, or the "
        text += "workout detail Health recorded. Those are dropped here on "
        text += "purpose, to make something readable.\n\n"
        text += "If you want everything Health returned, export again as "
        text += "**NDJSON**, **JSON**, or **SQLite**. Those keep every record. "
        text += "This one cannot, and would rather say so than let you find "
        text += "out later.\n\n"

        text += "## How days were decided\n\n"
        text += "Days are calendar days in **\(metadata.timeZone.identifier)**, "
        text += "the time zone this phone was in when the export ran — not UTC, "
        text += "which would file an evening workout under the following "
        text += "morning. Records are filed under the day they started, except "
        text += "sleep, which is filed under the day it ended, because last "
        text += "night's sleep belongs to the morning you woke up.\n\n"

        text += "## What this export contained\n\n"
        text += "| | |\n| --- | --- |\n"
        text += "| Records read | \(grouped(Double(statistics.linesRead))) |\n"
        text += "| Samples summarised | \(grouped(Double(statistics.samplesSummarised))) |\n"
        text += "| Workouts | \(grouped(Double(statistics.workoutsSummarised))) |\n"
        if statistics.deletionsSeen > 0 {
            text += "| Deletions (no day to file them under) "
            text += "| \(grouped(Double(statistics.deletionsSeen))) |\n"
        }
        if statistics.encodingIssues > 0 {
            text += "| Records Hozz could not encode | "
            text += "\(grouped(Double(statistics.encodingIssues))) |\n"
        }
        if statistics.undatedRecords > 0 {
            text += "| Records without a date | "
            text += "\(grouped(Double(statistics.undatedRecords))) |\n"
        }
        if statistics.unreadableLines > 0 {
            text += "| Records Hozz could not read | "
            text += "\(grouped(Double(statistics.unreadableLines))) |\n"
        }
        text += "\nDeletions and anything undated are listed in "
        text += "`export-log.ndjson` and kept in full by the other formats.\n\n"

        if !coverage.isEmpty {
            text += "## Types\n\n"
            text += "Apple does not let an app tell a Health type you denied "
            text += "from one that simply had no data, so a type that returned "
            text += "nothing is reported as indeterminate rather than as "
            text += "either.\n\n"
            text += "| Type | Result | Records |\n| --- | --- | --- |\n"
            for entry in coverage.sorted(by: { $0.name < $1.name }) {
                text += "| \(escape(entry.name)) | \(escape(entry.state)) | "
                text += "\(entry.records.map { grouped(Double($0)) } ?? "—") |\n"
            }
            text += "\n"
        }

        try archive.beginEntry(name: "README.md")
        try archive.write(Data(text.utf8))
        try archive.endEntry()
    }

    // MARK: - Accumulators

    /// Type identifiers are interned so a day's totals hold a small integer
    /// rather than another copy of a long HealthKit identifier.
    struct TypeTable {
        private var identifiers: [String: Int] = [:]
        private var names: [String] = []
        private var averaged: Set<Int> = []

        mutating func identifier(for type: String) -> Int {
            if let existing = identifiers[type] {
                return existing
            }
            let id = names.count
            identifiers[type] = id
            names.append(
                HealthTypeCatalog.entriesByIdentifier[type]?.displayName ?? type
            )
            if ExportMarkdownWriter.averagedIdentifiers.contains(type) {
                averaged.insert(id)
            }
            return id
        }

        func existingIdentifier(for type: String) -> Int? {
            identifiers[type]
        }

        func name(for id: Int) -> String {
            id < names.count ? names[id] : "Unknown"
        }

        /// Whether adding this type's readings together would produce a number
        /// that looks like data and means nothing.
        func isAveraged(_ id: Int) -> Bool {
            averaged.contains(id)
        }
    }

    struct Totals {
        var count = 0
        var valueCount = 0
        var sum = 0.0
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var unit: String?

        var average: Double {
            valueCount == 0 ? 0 : sum / Double(valueCount)
        }
    }

    struct WorkoutLine {
        let startTime: String
        let activity: String
        let seconds: Double
    }

    /// One day's worth of everything, in fixed space. Nothing here grows with
    /// the number of records the day contained.
    struct DaySummary {
        var recordCount = 0
        var totals: [Int: Totals] = [:]
        var workouts: [WorkoutLine] = []
        var workoutCount = 0
        var workoutSeconds = 0.0
        var asleepSeconds = 0.0
        var inBedSeconds = 0.0
        var sleepSegments = 0

        mutating func count(typeID: Int) {
            var entry = totals[typeID] ?? Totals()
            entry.count += 1
            totals[typeID] = entry
        }

        /// Folds one record into the day, in place.
        mutating func absorb(
            _ record: ExportRecord,
            typeID: Int?,
            isSleep: Bool,
            timeZone: TimeZone
        ) {
            recordCount += 1

            if record.kind == "workout" {
                add(
                    workout: record,
                    startedAt: record.startDate,
                    timeZone: timeZone
                )
                if let typeID {
                    count(typeID: typeID)
                }
                return
            }

            if isSleep {
                add(sleep: record)
            }
            guard let typeID else {
                return
            }
            // Only quantities carry a measurement. A category value is an
            // enumeration, so summing or averaging it would produce a number
            // that looks like data and means nothing.
            if record.kind == "quantity", let value = record.value {
                add(value: value, typeID: typeID, unit: record.unit)
            } else {
                count(typeID: typeID)
            }
        }

        mutating func add(value: Double, typeID: Int, unit: String?) {
            var entry = totals[typeID] ?? Totals()
            entry.count += 1
            entry.valueCount += 1
            entry.sum += value
            entry.minimum = Swift.min(entry.minimum, value)
            entry.maximum = Swift.max(entry.maximum, value)
            if entry.unit == nil {
                entry.unit = unit
            }
            totals[typeID] = entry
        }

        mutating func add(
            workout record: ExportRecord,
            startedAt: Date?,
            timeZone: TimeZone
        ) {
            workoutCount += 1
            let seconds = record.duration
                ?? Self.seconds(from: record.startDate, to: record.endDate)
            workoutSeconds += seconds
            guard workouts.count < ExportMarkdownWriter.workoutDetailLimit else {
                return
            }
            workouts.append(
                WorkoutLine(
                    startTime: startedAt.map {
                        ExportMarkdownWriter.clockTime($0, in: timeZone)
                    } ?? "—",
                    activity: ExportMarkdownWriter.activityName(
                        record.activityType
                    ),
                    seconds: seconds
                )
            )
        }

        /// Counts a sleep record. The seconds are *not* added here.
        ///
        /// Overlapping records describe the same night, so their durations
        /// cannot be added as they arrive — they are merged across the whole
        /// export first and filed afterwards. `sleepSegments` stays a count of
        /// records, which is what it has always been and is honest as it is.
        mutating func add(sleep record: ExportRecord) {
            sleepSegments += 1
        }

        func total(of type: String, in types: TypeTable) -> Double? {
            guard
                let id = types.existingIdentifier(for: type),
                let entry = totals[id],
                entry.valueCount > 0
            else {
                return nil
            }
            return entry.sum
        }

        func average(of type: String, in types: TypeTable) -> Double? {
            guard
                let id = types.existingIdentifier(for: type),
                let entry = totals[id],
                entry.valueCount > 0
            else {
                return nil
            }
            return entry.average
        }

        func entry(for type: String, in types: TypeTable) -> Totals? {
            guard let id = types.existingIdentifier(for: type) else {
                return nil
            }
            return totals[id]
        }

        private static func seconds(from start: Date?, to end: Date?) -> Double {
            guard let start, let end else {
                return 0
            }
            return Swift.max(0, end.timeIntervalSince(start))
        }
    }

    struct TypeCoverage {
        let name: String
        let state: String
        let records: Int?

        init(_ record: ExportRecord) {
            let identifier = record.type ?? "Unknown"
            name = HealthTypeCatalog.entriesByIdentifier[identifier]?.displayName
                ?? identifier
            state = (record.object["state"] as? String)
                ?? (record.object["coverage"] as? String)
                ?? "unknown"
            records = ExportRecord.number(record.object["records"]).map { Int($0) }
        }
    }

    // MARK: - Which numbers get promoted

    private enum Aggregation {
        /// Summed, because the type counts things that accumulate over a day.
        case total
        /// Averaged, because the type measures a state that is sampled.
        case mean
    }

    private struct Highlight {
        let identifier: String
        let key: String
        let aggregation: Aggregation
    }

    private static let stepCount = "HKQuantityTypeIdentifierStepCount"
    private static let distanceWalkingRunning =
        "HKQuantityTypeIdentifierDistanceWalkingRunning"
    private static let activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
    private static let restingHeartRate =
        "HKQuantityTypeIdentifierRestingHeartRate"
    private static let sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"

    /// The fields worth promoting into front matter, and whether a day's worth
    /// of one is a total or an average.
    ///
    /// The distinction is a judgement about what a person means: a day's steps
    /// are the sum of every reading, a day's heart rate is not. Every type,
    /// promoted or not, still appears in the note's table with both its total
    /// and its average, so the judgement narrows what is prominent rather than
    /// what is available.
    private static let highlights: [Highlight] = [
        Highlight(identifier: stepCount, key: "steps", aggregation: .total),
        Highlight(
            identifier: distanceWalkingRunning,
            key: "distance",
            aggregation: .total
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierDistanceCycling",
            key: "cycling_distance",
            aggregation: .total
        ),
        Highlight(identifier: activeEnergy, key: "active_energy", aggregation: .total),
        Highlight(
            identifier: "HKQuantityTypeIdentifierBasalEnergyBurned",
            key: "basal_energy",
            aggregation: .total
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierAppleExerciseTime",
            key: "exercise",
            aggregation: .total
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierFlightsClimbed",
            key: "flights_climbed",
            aggregation: .total
        ),
        Highlight(
            identifier: restingHeartRate,
            key: "resting_heart_rate",
            aggregation: .mean
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierHeartRate",
            key: "heart_rate",
            aggregation: .mean
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            key: "hrv",
            aggregation: .mean
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierRespiratoryRate",
            key: "respiratory_rate",
            aggregation: .mean
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierOxygenSaturation",
            key: "oxygen_saturation",
            aggregation: .mean
        ),
        Highlight(
            identifier: "HKQuantityTypeIdentifierBodyMass",
            key: "body_mass",
            aggregation: .mean
        )
    ]

    /// The types whose readings are measurements of a state rather than things
    /// that accumulate, so a day's worth of one is an average and never a sum.
    static let averagedIdentifiers: Set<String> = Set(
        highlights.filter { $0.aggregation == .mean }.map(\.identifier)
    )

    /// Whether a record is a page of a series' detail rather than a reading in
    /// its own right.
    static func isSeriesDetail(_ kind: String) -> Bool {
        SeriesEncoding.isDetailKind(kind)
    }

    /// A workout's activity, named where Hozz knows the name and numbered
    /// honestly where it does not.
    ///
    /// HealthKit exposes no way to ask an activity type for its own name, so
    /// this is a table. An unrecognised value is reported as the number Health
    /// gave, rather than guessed at or dropped.
    static func activityName(_ activityType: Int64?) -> String {
        guard let activityType else {
            return "Workout"
        }
        return activityNames[activityType] ?? "Activity \(activityType)"
    }

    private static let activityNames: [Int64: String] = [
        1: "American football", 2: "Archery", 3: "Australian football",
        4: "Badminton", 5: "Baseball", 6: "Basketball", 7: "Bowling",
        8: "Boxing", 9: "Climbing", 10: "Cricket", 11: "Cross training",
        12: "Curling", 13: "Cycling", 14: "Dance", 15: "Dance",
        16: "Elliptical", 17: "Equestrian sports", 18: "Fencing",
        19: "Fishing", 20: "Functional strength training", 21: "Golf",
        22: "Gymnastics", 23: "Handball", 24: "Hiking", 25: "Hockey",
        26: "Hunting", 27: "Lacrosse", 28: "Martial arts", 29: "Mind and body",
        30: "Mixed cardio", 31: "Paddle sports", 32: "Play",
        33: "Preparation and recovery", 34: "Racquetball", 35: "Rowing",
        36: "Rugby", 37: "Running", 38: "Sailing", 39: "Skating",
        40: "Snow sports", 41: "Soccer", 42: "Softball", 43: "Squash",
        44: "Stair climbing", 45: "Surfing", 46: "Swimming",
        47: "Table tennis", 48: "Tennis", 49: "Track and field",
        50: "Traditional strength training", 51: "Volleyball", 52: "Walking",
        53: "Water fitness", 54: "Water polo", 55: "Water sports",
        56: "Wrestling", 57: "Yoga", 58: "Barre", 59: "Core training",
        60: "Cross-country skiing", 61: "Downhill skiing", 62: "Flexibility",
        63: "High intensity interval training", 64: "Jump rope",
        65: "Kickboxing", 66: "Pilates", 67: "Snowboarding", 68: "Stairs",
        69: "Step training", 70: "Wheelchair walk pace",
        71: "Wheelchair run pace", 72: "Tai chi", 73: "Mixed cardio",
        74: "Hand cycling", 75: "Disc sports", 76: "Fitness gaming",
        77: "Cardio dance", 78: "Social dance", 79: "Pickleball",
        80: "Cooldown", 82: "Swim bike run", 83: "Transition",
        84: "Underwater diving", 3_000: "Other"
    ]

    // MARK: - Formatting

    private static func key(_ base: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty, unit != "count" else {
            return base
        }
        let suffix = unit
            .replacingOccurrences(of: "/", with: "_per_")
            .replacingOccurrences(of: "%", with: "percent")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return suffix.isEmpty ? base : "\(base)_\(suffix)"
    }

    private static func distanceText(_ totals: Totals) -> String? {
        guard totals.valueCount > 0 else {
            return nil
        }
        switch totals.unit {
        case "m":
            return "**\(plain(totals.sum / 1_000)) km**"
        case "km", "mi", "ft", "yd":
            return "**\(plain(totals.sum)) \(totals.unit ?? "")**"
        default:
            return nil
        }
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else {
            return "\(Int(seconds.rounded())) s"
        }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else {
            return "\(minutes) m"
        }
        let remainder = minutes % 60
        let hours = minutes / 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) m"
    }

    /// Digits grouped with thin separators, without asking the locale — a file
    /// format should read the same wherever it is opened.
    static func grouped(_ value: Double) -> String {
        guard value.isFinite else {
            return "—"
        }
        let rounded = value.rounded()
        let isWhole = abs(value - rounded) < 0.005
        let whole = abs(isWhole ? rounded : value.rounded(.towardZero))
        var digits = String(Int64(whole))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: digits.index(digits.startIndex, offsetBy: index))
            index -= 3
        }
        let sign = value < 0 ? "-" : ""
        guard !isWhole else {
            return sign + digits
        }
        let fraction = Int(((abs(value) - whole) * 100).rounded())
        return sign + digits + String(format: ".%02d", fraction)
    }

    static func plain(_ value: Double) -> String {
        ExportRecord.plain(value)
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// A pipe inside a cell would silently add a column.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func weekday(_ dayNumber: Int) -> String {
        // 1 January 1970 was a Thursday, which is index 4 counting from Sunday.
        let index = ((dayNumber + 4) % 7 + 7) % 7
        return [
            "Sunday", "Monday", "Tuesday", "Wednesday",
            "Thursday", "Friday", "Saturday"
        ][index]
    }

    private static func month(_ month: Int) -> String {
        let names = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        return (1...12).contains(month) ? names[month - 1] : "Month \(month)"
    }

    static func clockTime(_ date: Date, in timeZone: TimeZone) -> String {
        let local = date.timeIntervalSince1970
            + Double(timeZone.secondsFromGMT(for: date))
        let secondsIntoDay = Int(local.rounded(.down)) % 86_400
        let positive = (secondsIntoDay + 86_400) % 86_400
        return String(
            format: "%02d:%02d",
            positive / 3_600,
            (positive % 3_600) / 60
        )
    }

    private static func shortTimestamp(
        _ date: Date,
        in timeZone: TimeZone
    ) -> String {
        let local = date.timeIntervalSince1970
            + Double(timeZone.secondsFromGMT(for: date))
        let dayNumber = Int((local / 86_400).rounded(.down))
        let civil = LocalDayFormatter.civilFromDays(dayNumber)
        return "\(civil.day) \(month(civil.month)) \(civil.year) at "
            + "\(clockTime(date, in: timeZone))"
    }
}

private extension String {
    var capitalisedFirst: String {
        guard let first else {
            return self
        }
        return first.uppercased() + dropFirst()
    }
}
