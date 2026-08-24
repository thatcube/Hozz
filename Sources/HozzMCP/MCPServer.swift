import Foundation
import HozzCore
import HozzReceive

/// A Model Context Protocol server over the received Health data.
///
/// This is the point of receiving on a computer. Files in a folder are inert;
/// this lets the user point any MCP-capable assistant at their own data and ask
/// real questions about it — "how has my resting heart rate moved this year",
/// "did my sleep change after I started that medication" — without the data
/// ever leaving the machine or passing through anyone's service.
///
/// Three rules shape everything here:
///
/// 1. **Read-only.** No tool can modify or delete anything. The receiver's copy
///    is derived data, but it is still the user's health record.
/// 2. **Aggregates before rows.** Tools return summaries and buckets by
///    default. Handing an assistant a million raw samples would be slower,
///    less useful, and would spread far more personal detail than the question
///    needed.
/// 3. **No silent emptiness.** A type with no data says so, rather than
///    returning an empty list that reads like a confident zero.
public actor MCPServer {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "hozz"

    private let store: IngestStore
    private let version: String

    public init(store: IngestStore, version: String = "1.0.0") {
        self.store = store
        self.version = version
    }

    /// Handles one JSON-RPC message and returns the reply, if any.
    ///
    /// Notifications have no `id` and must not be answered — replying to one is
    /// a protocol violation that some clients treat as fatal.
    public func handle(_ message: Data) async -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        else {
            return encode(
                JSONRPC.error(id: nil, code: -32700, message: "Parse error")
            )
        }

        let id = object["id"]
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]

        if id == nil {
            // A notification. `initialized` is the common one; nothing to do.
            return nil
        }

        switch method {
        case "initialize":
            return encode(JSONRPC.result(id: id, result: initializeResult()))
        case "tools/list":
            return encode(JSONRPC.result(id: id, result: ["tools": Tools.all]))
        case "tools/call":
            return encode(await callTool(id: id, params: params))
        case "ping":
            return encode(JSONRPC.result(id: id, result: [:]))
        default:
            return encode(
                JSONRPC.error(
                    id: id,
                    code: -32601,
                    message: "Unknown method: \(method)"
                )
            )
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": Self.protocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": Self.serverName, "version": version]
        ]
    }

    private func callTool(id: Any?, params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text = try await run(tool: name, arguments: arguments)
            return JSONRPC.result(
                id: id,
                result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ]
            )
        } catch {
            // Reported as tool output rather than a protocol error, so the
            // assistant can read the reason and adjust instead of failing.
            return JSONRPC.result(
                id: id,
                result: [
                    "content": [[
                        "type": "text",
                        "text": "That did not work: \(error.localizedDescription)"
                    ]],
                    "isError": true
                ]
            )
        }
    }

    func run(tool name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_health_types":
            return try await listTypes()
        case "summarise_health_data":
            return try await summarise(arguments)
        case "aggregate_health_data":
            return try await aggregate(arguments)
        case "list_health_samples":
            return try await samples(arguments)
        case "list_electrocardiograms":
            return try await electrocardiograms(arguments)
        case "get_electrocardiogram_voltages":
            return try await voltages(arguments)
        case "list_audiograms":
            return try await audiograms(arguments)
        case "analyse_health_trend":
            return try await analyseTrend(arguments)
        case "compare_health_types":
            return try await compareTypes(arguments)
        case "find_health_anomalies":
            return try await findAnomalies(arguments)
        case "list_mood_entries":
            return try await moodEntries(arguments)
        case "summarise_medication_adherence":
            return try await medicationAdherence(arguments)
        case "list_workouts":
            return try await workouts(arguments)
        default:
            throw MCPError.unknownTool(name)
        }
    }

    // MARK: - Tools


    // MARK: - Analysis

    /// Which daily figure represents a type.
    ///
    /// Steps accumulate through a day, so a day's step count is the sum. A
    /// heart rate is sampled, so a day's heart rate is the average. Summing
    /// heart rates produces a number that means nothing, and the tools say
    /// which they used so nobody has to guess.
    ///
    /// Deferred to ``HealthMeasure``, which is the app's one table of what a
    /// type is. This used to be a hand-kept list of eleven identifiers beside
    /// it, and it had drifted: dietary protein, wheelchair distance, time in
    /// daylight, move time, swimming strokes, push count and several more were
    /// absent, so every one of them was *averaged* across a day by the trend,
    /// comparison and anomaly tools. A day's protein reported as the mean of
    /// each thing eaten is not a day's protein.
    private static func measure(for type: String) -> HealthMeasure {
        HealthMeasure.measure(for: type, storedUnit: nil)
    }

    private static func statisticName(for type: String) -> String {
        switch measure(for: type).kind {
        case .total: "daily total"
        case .average: "daily average"
        case .duration: "daily time"
        case .occurrences: "daily count"
        }
    }

    /// The unit the *daily figure* is in, which is not always the unit the
    /// samples are stored in.
    ///
    /// `dailySeries` reports what a day of a type means, and for a duration
    /// that is seconds and for an occurrence it is a bare count. Taking the
    /// unit from the stored rows instead printed a workout *count* as "sec",
    /// because a workout sample stores its duration and carries that unit —
    /// a number labelled as something it is not.
    private static func seriesUnit(
        for type: String,
        storedUnit: String?
    ) -> String {
        switch measure(for: type).kind {
        case .duration: "seconds"
        case .occurrences: ""
        case .total, .average: storedUnit ?? ""
        }
    }

    /// A range boundary, or nothing when the argument was not given.
    ///
    /// Throws rather than returning nil for an argument that *was* given and
    /// could not be read.
    private static func boundary(
        _ raw: Any?,
        name: String,
        edge: QueryTimestamp.Edge
    ) throws -> Date? {
        // A JSON `null` decodes to `NSNull`, which is not `nil`. A model
        // filling a schema emits one for every optional property it has no
        // value for, and refusing those would fail calls that are perfectly
        // well formed. An explicit null means "no bound", the same as omitting
        // the key.
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String else {
            throw MCPError.unreadableArgument(
                name: name,
                value: String(describing: raw),
                expected: "a date or timestamp as a string"
            )
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return try QueryTimestamp.parse(text, as: edge, argument: name)
    }

    /// A range that runs backwards is a swapped pair of arguments.
    ///
    /// Left alone it produced no rows, which the tool then reported as "has no
    /// records in that range" — an answer that looks entirely normal and reads
    /// as "you have no data". Same class as the silently discarded filter.
    private static func checkOrder(from: Date?, to: Date?) throws {
        guard let from, let to, from > to else { return }
        throw MCPError.unreadableArgument(
            name: "to",
            value: Self.day(to),
            expected: "a date on or after \"from\" (\(Self.day(from))); "
                + "the range appears to be the wrong way round"
        )
    }

    /// The requested bucket, or an error naming the ones that exist.
    ///
    /// A misspelling used to fall through to `.day`, so asking for "weekly"
    /// quietly answered by day and the reply's own header said so in a line
    /// nobody reads twice.
    private static func bucket(_ raw: Any?) throws -> BucketSize {
        guard let raw, !(raw is NSNull) else { return .day }
        guard let text = raw as? String, !text.isEmpty else {
            throw MCPError.unreadableArgument(
                name: "bucket",
                value: String(describing: raw),
                expected: BucketSize.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        guard let bucket = BucketSize(rawValue: text) else {
            throw MCPError.unreadableArgument(
                name: "bucket",
                value: text,
                expected: "one of "
                    + BucketSize.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        return bucket
    }

    /// A type's daily series, plus how many records backed each day.
    private func dailySeries(
        type: String,
        days: Int,
        now: Date
    ) async throws -> [HealthStatistics.DailyValue] {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let buckets = try await store.aggregate(
            type: type,
            bucket: .day,
            from: start,
            to: now
        )
        return buckets.map { bucket in
            HealthStatistics.DailyValue(
                day: Double(
                    LocalDayExpression.day(for: bucket.start, timeZone: .current)
                ),
                // The figure the store says means something for this type,
                // rather than one of two picked here. For a category type both
                // of those were arithmetic on enumeration cases.
                value: bucket.value,
                recordCount: bucket.count
            )
        }
    }

    /// Says why a type has nothing, because "not synced yet" and "no such
    /// type" and "nothing in this window" are three different answers and only
    /// one of them means the person has no such data.
    private func explainEmptySeries(_ type: String, days: Int) async throws -> String {
        let known = try await store.summaries()
        guard let summary = known.first(where: { $0.type == type }) else {
            let names = known.map(\.type).sorted().prefix(20).joined(separator: ", ")
            return """
                No \(type) has reached this Mac yet. Your phone syncs one type \
                at a time and may not have reached this one; it is not \
                evidence that you have no such data. Types received so far: \
                \(names.isEmpty ? "none" : names).
                """
        }
        // "None in this window" is only true if the dates are the reason. A
        // type whose records carry no number at all is present and unchartable,
        // and reporting that as a date problem is a false explanation.
        let inWindow = try await store.samples(
            type: type,
            from: Date.now.addingTimeInterval(-Double(days) * 86_400),
            to: .now,
            limit: 1
        )
        guard inWindow.isEmpty else {
            return """
                \(type) has \(summary.recordCount) records, including some in \
                the last \(days) days, but none of them carry a number this \
                tool can chart. Use list_health_samples to see them.
                """
        }
        return """
            \(type) has \(summary.recordCount) records, but none in the last \
            \(days) days. Widen the window to reach them.
            """
    }

    private func analyseTrend(_ arguments: [String: Any]) async throws -> String {
        guard let type = arguments["type"] as? String else {
            throw MCPError.missingArgument("type")
        }
        let days = min(max((arguments["days"] as? Int) ?? 90, 1), 3_650)
        let series = try await dailySeries(type: type, days: days, now: .now)

        guard !series.isEmpty else {
            return try await explainEmptySeries(type, days: days)
        }

        let points = series.map { (day: $0.day, value: $0.value) }
        guard let trend = HealthStatistics.trend(points) else {
            return """
                Only \(series.count) days of \(type) in the last \(days) days. \
                A trend needs at least \(HealthStatistics.minimumTrendDays) \
                days; below that a fitted line describes the noise. No \
                direction should be reported.
                """
        }

        let unit = Self.seriesUnit(
            for: type,
            storedUnit: (try await store.summaries()).first { $0.type == type }?.unit
        )
        var text = "\(type), \(Self.statisticName(for: type)), "
        text += "\(trend.dayCount) days with data in the last \(days).\n\n"

        guard trend.isDetectable else {
            // The interval spans zero, so a flat line fits as well as a sloped
            // one. Reporting the slope's sign here would be inventing a
            // direction the data does not carry.
            text += """
                No detectable change. The fitted slope is \
                \(Self.number(trend.perWeek)) \(unit) per week, but its 95% \
                interval spans zero \
                (\(Self.number(trend.confidenceLow * 7)) to \
                \(Self.number(trend.confidenceHigh * 7)) per week), so a flat \
                line fits these points just as well. Do not describe this as \
                rising or falling.
                """
            return text
        }

        text += """
            \(trend.direction.capitalized): \(Self.number(trend.perWeek)) \
            \(unit) per week (95% interval \
            \(Self.number(trend.confidenceLow * 7)) to \
            \(Self.number(trend.confidenceHigh * 7))). \
            About \(Self.number(trend.startValue)) at the start of the window \
            and \(Self.number(trend.endValue)) at the end.
            """
        if trend.rSquared < 0.2 {
            text += """
                \n\nThe line accounts for only \
                \(Int((trend.rSquared * 100).rounded()))% of the variation, so \
                day-to-day scatter is much larger than the drift. The direction \
                is supportable; describing it as pronounced is not.
                """
        }
        text += "\n\n\(Self.dayBasis)"
        return text
    }

    private func compareTypes(_ arguments: [String: Any]) async throws -> String {
        guard let first = arguments["first"] as? String else {
            throw MCPError.missingArgument("first")
        }
        guard let second = arguments["second"] as? String else {
            throw MCPError.missingArgument("second")
        }
        let days = min(max((arguments["days"] as? Int) ?? 180, 1), 3_650)
        let now = Date.now

        let firstSeries = try await dailySeries(type: first, days: days, now: now)
        let secondSeries = try await dailySeries(type: second, days: days, now: now)

        // The backfill sends one type at a time, so a missing second type is
        // usually "not synced yet" rather than "you have none of this".
        if firstSeries.isEmpty {
            return try await explainEmptySeries(first, days: days)
        }
        if secondSeries.isEmpty {
            return try await explainEmptySeries(second, days: days)
        }

        guard
            let correlation = HealthStatistics.correlation(
                firstSeries.map { (day: $0.day, value: $0.value) },
                secondSeries.map { (day: $0.day, value: $0.value) }
            )
        else {
            let overlap = Set(firstSeries.map(\.day))
                .intersection(secondSeries.map(\.day))
                .count
            return """
                Only \(overlap) days have both \(first) and \(second). \
                Comparing two types needs at least \
                \(HealthStatistics.minimumCorrelationDays) shared days, so no \
                relationship should be reported either way.
                """
        }

        var text = "\(first) vs \(second), "
        text += "\(correlation.pairedDays) shared days "
        text += "(worth about \(Int(correlation.effectiveDays.rounded())) "
        text += "independent days once day-to-day similarity is accounted for)."
        text += "\n\n"

        guard correlation.isDetectable else {
            text += """
                No detectable relationship. The correlation is \
                \(Self.number(correlation.coefficient)) but its 95% interval \
                (\(Self.number(correlation.confidenceLow)) to \
                \(Self.number(correlation.confidenceHigh))) includes zero. \
                Do not describe these as related.
                """
            return text
        }

        text += """
            \(correlation.strength.capitalized) \
            \(correlation.coefficient > 0 ? "positive" : "negative") \
            correlation: \(Self.number(correlation.coefficient)) \
            (95% interval \(Self.number(correlation.confidenceLow)) to \
            \(Self.number(correlation.confidenceHigh))). They tend to move \
            \(correlation.coefficient > 0 ? "together" : "in opposite directions").
            """

        if correlation.bothTrending {
            // The most common way this number misleads.
            text += """
                \n\nCaution: both are trending over this window. Two \
                quantities that both drift will correlate whether or not they \
                are related, so this may reflect nothing more than that shared \
                drift.
                """
        }
        text += """
            \n\nThis is association, not cause. Nothing here shows one \
            affects the other, and an unmeasured third thing may drive both.
            """
        text += "\n\n\(Self.dayBasis)"
        return text
    }

    private func findAnomalies(_ arguments: [String: Any]) async throws -> String {
        guard let type = arguments["type"] as? String else {
            throw MCPError.missingArgument("type")
        }
        let days = min(max((arguments["days"] as? Int) ?? 90, 1), 3_650)
        let series = try await dailySeries(type: type, days: days, now: .now)

        guard !series.isEmpty else {
            return try await explainEmptySeries(type, days: days)
        }
        guard let report = HealthStatistics.anomalies(series) else {
            return """
                Only \(series.count) days of \(type) in the last \(days) days. \
                Judging a day as unusual needs at least \
                \(HealthStatistics.minimumBaselineDays) days to establish what \
                usual is.
                """
        }

        let unit = Self.seriesUnit(
            for: type,
            storedUnit: (try await store.summaries()).first { $0.type == type }?.unit
        )
        var text = "\(type), \(Self.statisticName(for: type)). "
        text += "Usual value \(Self.number(report.median)) \(unit) "
        text += "across \(report.consideredDays) days judged.\n\n"

        if report.outliers.isEmpty {
            text += "Nothing unusual: no day differs from the usual value by "
            text += "more than three robust deviations."
        } else {
            text += "Unusual days:\n"
            text += report.outliers.prefix(20)
                .map { outlier in
                    let day = LocalDayExpression.date(
                        forDay: Int(outlier.day),
                        timeZone: .current
                    )
                    return "- \(Self.day(day)): \(Self.number(outlier.value)) "
                        + "\(unit), \(Self.number(abs(outlier.deviations))) "
                        + "deviations \(outlier.isHigh ? "above" : "below") usual "
                        + "(\(outlier.recordCount) records)"
                }
                .joined(separator: "\n")
        }

        if !report.lowCoverageDays.isEmpty {
            // Reported separately and explicitly, because a day the watch was
            // off looks exactly like a collapsed reading to anything that does
            // not check how much was recorded.
            text += "\n\n\(report.lowCoverageDays.count) "
            text += report.lowCoverageDays.count == 1 ? "day was" : "days were"
            text += " not judged because too little was recorded that day — "
            text += "most likely the device was not worn. These are missing "
            text += "measurements, not low readings, and must not be reported "
            text += "as unusual values: "
            text += report.lowCoverageDays.sorted().prefix(10)
                .map {
                    Self.day(
                        LocalDayExpression.date(
                            forDay: Int($0),
                            timeZone: .current
                        )
                    )
                }
                .joined(separator: ", ")
            text += "."
        }
        text += "\n\n\(Self.dayBasis)"
        return text
    }


    private func moodEntries(_ arguments: [String: Any]) async throws -> String {
        let days = min(max((arguments["days"] as? Int) ?? 90, 1), 3_650)
        let limit = min((arguments["limit"] as? Int) ?? 100, 1_000)
        let entries = try await store.moodEntries(
            from: Date.now.addingTimeInterval(-Double(days) * 86_400),
            limit: limit
        )
        guard !entries.isEmpty else {
            return """
                No State of Mind entries in the last \(days) days. If your \
                phone has not finished its first sync this may simply not have \
                arrived yet, rather than not existing.
                """
        }

        var text = "\(entries.count) mood entries. Valence runs -1 (very "
        text += "unpleasant) to +1 (very pleasant).\n\n"
        text += "date, valence, felt, kind, labels, associations\n"
        text += entries
            .map { entry in
                [
                    Self.day(entry.startDate),
                    Self.number(entry.valence),
                    entry.classification ?? "",
                    entry.kindOfEntry ?? "",
                    entry.labels,
                    entry.associations
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        return text
    }

    private func medicationAdherence(_ arguments: [String: Any]) async throws -> String {
        let days = min(max((arguments["days"] as? Int) ?? 90, 1), 3_650)
        let adherence = try await store.medicationAdherence(
            from: Date.now.addingTimeInterval(-Double(days) * 86_400)
        )
        guard !adherence.isEmpty else {
            return """
                No medication doses in the last \(days) days. If your phone \
                has not finished its first sync this may simply not have \
                arrived yet, rather than not existing.
                """
        }

        var text = ""
        for entry in adherence {
            text += "\(entry.medication): \(entry.total) logged "
            text += entry.total == 1 ? "dose" : "doses"
            if let earliest = entry.earliest, let latest = entry.latest {
                text += " between \(Self.day(earliest)) and \(Self.day(latest))"
            }
            text += "\n"
            for status in entry.statusCounts.keys.sorted() {
                let count = entry.statusCounts[status] ?? 0
                text += "  \(status): \(count)\n"
            }
            // Stated per medicine so the distinction cannot be lost in a
            // summary written above it.
            text += "  (only 'taken' means it was taken; skipped, snoozed and "
            text += "notAnswered each mean it was not)\n\n"
        }
        return text
    }


    private func workouts(_ arguments: [String: Any]) async throws -> String {
        let days = min(max((arguments["days"] as? Int) ?? 90, 1), 3_650)
        let limit = min((arguments["limit"] as? Int) ?? 50, 500)
        let workouts = try await store.workouts(
            from: Date.now.addingTimeInterval(-Double(days) * 86_400),
            limit: limit
        )
        guard !workouts.isEmpty else {
            return """
                No workouts in the last \(days) days. If your phone has not \
                finished its first sync they may not have arrived yet, rather \
                than not existing.
                """
        }

        var text = ""
        for workout in workouts {
            text += "\(Self.day(workout.startDate)) — "
            text += Self.activityName(workout.activityType)
            if let duration = workout.duration {
                text += ", \(Int((duration / 60).rounded())) min"
            }
            if let source = workout.sourceName {
                text += ", from \(source)"
            }
            text += "\n"

            if workout.statistics.isEmpty {
                // Health did not compute any, which is different from Hozz
                // having failed to read them.
                text += "  (Health recorded no statistics for this workout)\n"
            }
            for statistic in workout.statistics {
                text += "  \(Self.describe(statistic))\n"
            }

            for (index, activity) in workout.activities.enumerated() {
                text += "  Leg \(index + 1): "
                text += Self.activityName(activity.activityType) + "\n"
                for statistic in activity.statistics {
                    text += "    \(Self.describe(statistic))\n"
                }
            }
            text += "\n"
        }
        return text
    }

    /// One statistic, reporting only the figures Health actually computed.
    ///
    /// A missing average is left out rather than shown as zero: Health does
    /// not compute every figure for every quantity, and a zero average heart
    /// rate would read as a measurement.
    private static func describe(
        _ statistic: IngestStore.StoredWorkoutStatistic
    ) -> String {
        var parts: [String] = []
        if let sum = statistic.sum {
            parts.append("total \(number(sum))")
        }
        if let average = statistic.average {
            parts.append("average \(number(average))")
        }
        if let minimum = statistic.minimum {
            parts.append("min \(number(minimum))")
        }
        if let maximum = statistic.maximum {
            parts.append("max \(number(maximum))")
        }
        let name = statistic.type
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
        let unit = statistic.unit.map { " \($0)" } ?? ""
        return "\(name): \(parts.joined(separator: ", "))\(unit)"
    }

    private static func activityName(_ activityType: Int?) -> String {
        guard let activityType else {
            return "Workout"
        }
        return activityNames[activityType] ?? "Activity \(activityType)"
    }

    private static let activityNames: [Int: String] = [
        13: "Cycling", 16: "Elliptical", 20: "Functional strength training",
        24: "Hiking", 35: "Rowing", 37: "Running", 44: "Stair climbing",
        46: "Swimming", 50: "Traditional strength training", 52: "Walking",
        57: "Yoga", 63: "High intensity interval training",
        82: "Swim bike run", 83: "Transition", 3_000: "Other"
    ]

    // MARK: - ECG and hearing

    private func electrocardiograms(_ arguments: [String: Any]) async throws -> String {
        let limit = min((arguments["limit"] as? Int) ?? 50, 500)
        let readings = try await store.electrocardiograms(limit: limit)
        guard !readings.isEmpty else {
            return "No ECG readings have been received."
        }

        var text = "\(readings.count) ECG "
        text += readings.count == 1 ? "reading" : "readings"
        text += ".\n\nid, start, classification, symptoms, average bpm, waveform\n"
        text += readings
            .map { reading in
                [
                    reading.id,
                    Timestamps.text(from: reading.startDate),
                    reading.classification ?? "unclassified",
                    reading.symptomsStatus ?? "unknown",
                    reading.averageHeartRate.map(Self.number) ?? "",
                    Self.waveformState(reading)
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        return text
    }

    /// Says what is actually held, because "complete" and "still arriving" are
    /// different claims and only one of them can be read as a whole recording.
    private static func waveformState(
        _ reading: IngestStore.StoredElectrocardiogram
    ) -> String {
        guard reading.heldVoltages > 0 else {
            return "no waveform received"
        }
        if reading.isComplete {
            return "complete (\(reading.heldVoltages) points)"
        }
        guard let expected = reading.expectedVoltages else {
            return "\(reading.heldVoltages) points, completeness unknown"
        }
        return "incomplete (\(reading.heldVoltages) of \(expected) points)"
    }

    private func voltages(_ arguments: [String: Any]) async throws -> String {
        guard let id = arguments["id"] as? String else {
            throw MCPError.missingArgument("id")
        }
        let limit = min((arguments["limit"] as? Int) ?? 500, 20_000)
        let waveform = try await store.voltages(forElectrocardiogram: id)

        guard !waveform.points.isEmpty else {
            // Distinguishing "no such reading" from "no waveform yet" matters:
            // an assistant told only "empty" will report the reading missing.
            let known = try await store.electrocardiograms(limit: 500)
                .map(\.id)
            if !known.contains(id) {
                return "There is no ECG reading with id \(id)."
            }
            return "That reading has arrived but its waveform has not."
        }

        var text = waveform.isComplete
            ? "Complete recording: \(waveform.points.count) points."
            : "INCOMPLETE recording: \(waveform.points.count) points held"
        if !waveform.isComplete {
            text += waveform.expected.map { " of \($0) expected" } ?? ""
            text += ". Do not read this as a whole trace."
        }
        text += "\n\nsecondsSinceStart, volts\n"

        text += waveform.points.prefix(limit)
            .map { point in
                String(format: "%.4f, %.7f", point.secondsSinceStart, point.volts)
            }
            .joined(separator: "\n")

        if waveform.points.count > limit {
            text += "\n\n(Truncated at \(limit) of \(waveform.points.count) points.)"
        }
        return text
    }

    private func audiograms(_ arguments: [String: Any]) async throws -> String {
        let limit = min((arguments["limit"] as? Int) ?? 20, 200)
        let tests = try await store.audiograms(limit: limit)
        guard !tests.isEmpty else {
            return "No hearing tests have been received."
        }

        var text = ""
        for test in tests {
            text += "Hearing test \(Self.day(test.startDate))"
            if let source = test.sourceName {
                text += " from \(source)"
            }
            text += "\n"
            if test.points.isEmpty {
                text += "  (no thresholds recorded)\n\n"
                continue
            }
            text += "  frequency, ear, threshold\n"
            for point in test.points {
                let value = point.sensitivity.map(Self.number) ?? "—"
                // A clamped reading is a bound: the difference between "90 dB"
                // and "at least 90 dB".
                let threshold = point.clamped ? "at least \(value)" : value
                text += "  \(Self.number(point.frequency)) Hz, \(point.ear), "
                text += "\(threshold) \(point.unit ?? "")\n"
            }
            text += "\n"
        }
        return text
    }

    private func listTypes() async throws -> String {
        let summaries = try await store.summaries()
        guard !summaries.isEmpty else {
            return """
                No Health data has been received yet. Open Hozz on the phone and \
                add this computer as a destination, then sync.
                """
        }
        let lines = summaries.map { summary in
            let range = [summary.earliest, summary.latest]
                .compactMap { $0 }
                .map(Self.day)
            let span = range.count == 2 ? " (\(range[0]) to \(range[1]))" : ""
            let unit = summary.unit.map { " \($0)" } ?? ""
            return "- \(summary.type): \(summary.recordCount) records\(unit)\(span)"
        }
        return "Health types available:\n" + lines.joined(separator: "\n")
    }

    private func summarise(_ arguments: [String: Any]) async throws -> String {
        let summaries = try await store.summaries()
        let total = try await store.totalRecordCount()
        let characteristics = try await store.characteristics()
        // Counted here rather than later, because "nothing received" has to be
        // false the moment anything has been — an ECG is not an ordinary
        // sample, and reporting an empty store while holding one is exactly
        // the confidently wrong answer this tool exists to avoid.
        let ecgCount = try await store.electrocardiograms(limit: 500).count
        let audiogramCount = try await store.audiograms(limit: 200).count

        guard
            !summaries.isEmpty
                || !characteristics.isEmpty
                || ecgCount > 0
                || audiogramCount > 0
        else {
            return "No Health data has been received yet."
        }

        var text = ""

        // Deliberately part of this tool rather than one of its own.
        //
        // These are what the measurements have to be read against: a resting
        // heart rate of 48 is athletic in a 34-year-old and worth a question in
        // a 70-year-old. A separate tool would be cleaner to describe and worse
        // in practice, because an assistant that is not required to call it
        // will answer "is this normal for me" without ever having asked who
        // "me" is. Putting it here means the context arrives with the
        // orientation step that every session already begins with.
        if !characteristics.isEmpty {
            text += "About the person:\n"
            for characteristic in characteristics {
                text += "- \(characteristic.displayName): "
                text += Self.describe(characteristic) + "\n"
            }
            text += "\n"
        }

        guard !summaries.isEmpty else {
            if ecgCount > 0 || audiogramCount > 0 {
                return text
                    + "No ordinary measurements yet, but \(ecgCount) ECG "
                    + "readings and \(audiogramCount) hearing tests have arrived."
            }
            return text + "No measurements have been received yet."
        }

        let earliest = summaries.compactMap(\.earliest).min()
        let latest = summaries.compactMap(\.latest).max()
        text += "\(total) records across \(summaries.count) types."
        if let earliest, let latest {
            text += " Covering \(Self.day(earliest)) to \(Self.day(latest))."
        }

        // A receiver holding records it could not interpret is not the same as
        // one holding nothing, and an assistant should not describe a partial
        // picture as a complete one.
        let unhandled = try await store.unhandledSummary()
        if !unhandled.isEmpty {
            let count = unhandled.reduce(0) { $0 + $1.count }
            text += " \(count) further "
            text += count == 1 ? "record was" : "records were"
            text += " received in a form this version of Hozz cannot read yet ("
            text += unhandled.map(\.kind).joined(separator: ", ")
            text += "); they are stored but not queryable here."
        }

        // Named separately because they are not ordinary samples: saying
        // "0 types" while holding 200 ECG readings would be false.
        if ecgCount > 0 {
            text += " \(ecgCount) ECG "
            text += ecgCount == 1 ? "reading" : "readings"
            text += " (list_electrocardiograms)."
        }
        if audiogramCount > 0 {
            text += " \(audiogramCount) hearing "
            text += audiogramCount == 1 ? "test" : "tests"
            text += " (list_audiograms)."
        }

        let biggest = summaries.sorted { $0.recordCount > $1.recordCount }.prefix(10)
        text += "\n\nLargest types:\n"
        text += biggest
            .map { "- \($0.type): \($0.recordCount)" }
            .joined(separator: "\n")
        return text
    }

    /// One characteristic, in the form an assistant can reason with.
    ///
    /// A date of birth is reported with the age it implies, because age is what
    /// every reference range is actually keyed to and an assistant that has to
    /// derive it may get it wrong. States other than "known" are reported as
    /// themselves: "not set" is a fact about the person, and reporting it as a
    /// blank would invite a confident answer built on a guess.
    public static func describe(_ characteristic: StoredCharacteristic) -> String {
        guard characteristic.isKnown, let value = characteristic.value else {
            return switch characteristic.state {
            case "notSet": "not set by the person"
            case "unavailable": "not available on their device"
            case "unrecognised": "a value this version of Hozz has no name for"
            case "unreadable": "could not be read"
            default: "unknown"
            }
        }

        if characteristic.type.hasSuffix("DateOfBirth"),
           let age = Self.age(fromDateOfBirth: value) {
            return "\(value) (age \(age))"
        }
        return value
    }

    /// Whole years between a `yyyy-MM-dd` birth date and today.
    public static func age(fromDateOfBirth text: String, now: Date = .now) -> Int? {
        let parts = text.prefix(10).split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            return nil
        }
        let today = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: now
        )
        guard
            let nowYear = today.year,
            let nowMonth = today.month,
            let nowDay = today.day
        else {
            return nil
        }
        var age = nowYear - year
        // A birthday later this year has not happened yet.
        if (nowMonth, nowDay) < (month, day) {
            age -= 1
        }
        return age >= 0 ? age : nil
    }

    private func aggregate(_ arguments: [String: Any]) async throws -> String {
        guard let type = arguments["type"] as? String else {
            throw MCPError.missingArgument("type")
        }
        let bucket = try Self.bucket(arguments["bucket"])
        let from = try Self.boundary(arguments["from"], name: "from", edge: .start)
        let to = try Self.boundary(arguments["to"], name: "to", edge: .end)
        try Self.checkOrder(from: from, to: to)

        let buckets = try await store.aggregate(
            type: type,
            bucket: bucket,
            from: from,
            to: to
        )
        guard !buckets.isEmpty else {
            // Distinguishing "no such type" from "no data in range" matters:
            // an assistant told only "empty" will confidently report a zero.
            let known = try await store.summaries().map(\.type)
            if !known.contains(type) {
                return """
                    There is no type called "\(type)". Available types: \
                    \(known.prefix(40).joined(separator: ", "))
                    """
            }
            return "\(type) has no records in that range."
        }

        let unit = try await store.summaries()
            .first { $0.type == type }?
            .unit

        let measure = Self.measure(for: type)
        var text = "\(type) by \(bucket.rawValue)"
        if let unit, measure.kind == .total || measure.kind == .average {
            text += " (\(unit))"
        }
        text += ":\n"

        switch measure.kind {
        case .total, .average:
            text += "date, sum, average, min, max, count\n"
            text += buckets
                .map { bucket in
                    [
                        Self.day(bucket.start),
                        Self.number(bucket.sum),
                        Self.number(bucket.average),
                        Self.number(bucket.minimum),
                        Self.number(bucket.maximum),
                        String(bucket.count)
                    ].joined(separator: ", ")
                }
                .joined(separator: "\n")
            text += """

                \nBoth sum and average are given because the right one depends \
                on the type: summing an instantaneous measure like heart rate \
                is meaningless, and averaging a cumulative one like step count \
                understates the period.
                """

        case .occurrences, .duration:
            // A category type's stored value is an enumeration case, so there
            // is no sum, average, minimum or maximum of it worth printing.
            // Offering those columns at all invites the reading they cannot
            // support, so they are simply not here.
            let heading = measure.kind == .duration ? "minutes" : "count"
            text += "date, \(heading), samples\n"
            text += buckets
                .map { bucket in
                    let value = measure.kind == .duration
                        ? bucket.value / 60
                        : bucket.value
                    return [
                        Self.day(bucket.start),
                        Self.number(value),
                        String(bucket.count)
                    ].joined(separator: ", ")
                }
                .joined(separator: "\n")
            text += "\n\n\(Self.categoryNote(for: type, measure: measure))"
        }

        text += "\n\n\(Self.dayBasis)"
        return text
    }

    /// What a category type's column actually counts, and why it is not a sum.
    private static func categoryNote(
        for type: String,
        measure: HealthMeasure
    ) -> String {
        switch type {
        case "HKCategoryTypeIdentifierAppleStandHour":
            return "The count is hours **stood**. "
                + "HKCategoryValueAppleStandHour records 0 for stood and 1 for "
                + "idle, so adding the stored numbers would total the idle "
                + "hours instead — the exact opposite — and a zero here means "
                + "a day recorded with no standing in it, not a day unrecorded."
        case "HKCategoryTypeIdentifierSleepAnalysis":
            return "Minutes are time **asleep**: the core, deep, REM and "
                + "unspecified-asleep stages only. Time in bed is not time "
                + "asleep and time awake is neither, so neither is counted. "
                + "A zero means a night recorded with no sleep staged in it. "
                + "Records covering the same minutes are merged rather than "
                + "added, so a night two devices both recorded counts once."
        default:
            return measure.kind == .duration
                ? "Minutes are the time these samples cover. Their stored "
                    + "values are enumeration cases, which is why no sum or "
                    + "average of them is given."
                : "The count is how many of these were recorded. Their stored "
                    + "values are enumeration cases, which is why no sum or "
                    + "average of them is given."
        }
    }

    private func samples(_ arguments: [String: Any]) async throws -> String {
        let type = arguments["type"] as? String
        let from = try Self.boundary(arguments["from"], name: "from", edge: .start)
        let to = try Self.boundary(arguments["to"], name: "to", edge: .end)
        try Self.checkOrder(from: from, to: to)
        let limit = min((arguments["limit"] as? Int) ?? 100, 1000)

        let records = try await store.samples(
            type: type,
            from: from,
            to: to,
            limit: limit
        )
        guard !records.isEmpty else {
            return "No samples matched."
        }
        var text = "type, start, value, unit, source\n"
        text += records
            .map { record in
                [
                    record.type,
                    Timestamps.text(from: record.startDate),
                    record.value.map(Self.number) ?? "",
                    record.unit ?? "",
                    record.sourceName ?? ""
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        if records.count == limit {
            text += "\n\n(Truncated at \(limit). Narrow the range or aggregate instead.)"
        }
        return text
    }

    // MARK: - Formatting

    private static func day(_ date: Date) -> String {
        // Local, not GMT. Buckets are now local days, so a local midnight
        // formatted in GMT would print the previous date for anyone ahead of
        // UTC — the same off-by-one this change exists to remove, just moved
        // from the grouping to the label.
        date.formatted(
            Date.ISO8601FormatStyle(timeZone: .current)
                .year().month().day()
        )
    }

    /// The zone the buckets were built in, said plainly wherever days are
    /// reported.
    ///
    /// Samples carry no record of the zone they were taken in — `raw` has the
    /// timestamps, the quantity, the device and the source, and its `metadata`
    /// is empty — so a reading taken while travelling cannot be attributed to
    /// the local day it actually happened on. Grouping in the reader's current
    /// zone is the best available answer and the one somebody means by "my
    /// Tuesday", but it is an assumption, and an assistant relaying a daily
    /// total should be able to say which day it meant.
    private static var dayBasis: String {
        "Days are calendar days in \(TimeZone.current.identifier), the time "
            + "zone this computer is set to. Samples do not record the zone "
            + "they were taken in, so readings from elsewhere are filed under "
            + "the local day they correspond to here."
    }

    private static func number(_ value: Double) -> String {
        // Health values are rarely meaningful past two decimals, and long
        // floating point tails make a table unreadable.
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum MCPError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case missingArgument(String)
    /// An argument that arrived but could not be understood.
    ///
    /// Reported rather than ignored. A filter that is quietly dropped returns
    /// an answer that looks entirely normal and is about the wrong period,
    /// which is the hardest kind of wrong to notice.
    case unreadableArgument(name: String, value: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "There is no tool called \"\(name)\"."
        case .missingArgument(let name):
            "The \"\(name)\" argument is required."
        case .unreadableArgument(let name, let value, let expected):
            "Could not read \"\(value)\" as the \"\(name)\" argument. "
                + "Expected \(expected). Nothing was returned rather than "
                + "ignoring the argument and answering about the wrong period."
        }
    }
}

enum JSONRPC {
    static func result(id: Any?, result: [String: Any]) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        message["id"] = id ?? NSNull()
        return message
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        payload["id"] = id ?? NSNull()
        return payload
    }
}

/// The tool definitions advertised to a client.
enum Tools {
    /// Computed rather than stored: `[String: Any]` is not `Sendable`, and a
    /// shared static would be mutable state across every connection.
    static var all: [[String: Any]] {
        [
        [
            "name": "list_health_types",
            "description": """
                List every Health data type that has been received, with how \
                many records each has and the dates they span. Call this first: \
                type names are HealthKit identifiers and cannot be guessed \
                reliably.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "summarise_health_data",
            "description": """
                An overview of everything received: total records, how many \
                types, the date range covered, and the largest types. Also \
                returns the person's own characteristics — age, biological \
                sex, blood type and so on — where they have been shared. Call \
                this before interpreting any measurement, because reference \
                ranges depend on them: a resting heart rate of 48 means \
                something different at 34 than at 70.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "aggregate_health_data",
            "description": """
                Aggregate one Health type into time buckets. For a \
                measured or cumulative type this returns sum, average, \
                minimum, maximum and count for each bucket. For a category \
                type — sleep, stand hours — the stored value is an \
                enumeration case with no meaningful sum, so the reply instead \
                gives the thing the type means: minutes asleep, or hours \
                stood. Every reply names its own columns. This is the right \
                tool for questions about trends over time. Prefer it over \
                fetching raw samples. Buckets are local calendar days, weeks \
                and months in the time zone this computer is set to, not UTC — \
                an evening reading belongs to that evening. Samples do not \
                record the zone they were taken in, so a reading from a trip \
                abroad is filed under the local day it corresponds to here; \
                the reply states which zone was used.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "The HealthKit type identifier, from list_health_types."
                    ],
                    "bucket": [
                        "type": "string",
                        "enum": BucketSize.allCases.map(\.rawValue),
                        "description": "Time grouping. Defaults to day."
                    ],
                    "from": [
                        "type": "string",
                        "description": "ISO 8601 start of range, inclusive. Optional."
                    ],
                    "to": [
                        "type": "string",
                        "description": "ISO 8601 end of range, inclusive. Optional."
                    ]
                ],
                "required": ["type"]
            ]
        ],
        [
            "name": "analyse_health_trend",
            "description": """
                Whether one type is drifting up or down over a window, with \
                the uncertainty attached. Returns "no detectable change" when \
                a flat line fits the data as well as a sloped one, and refuses \
                to answer at all below two weeks of days — a slope through \
                nine days describes noise. Do not describe a trend this tool \
                reports as undetectable, however suggestive the number looks.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "The HealthKit type identifier, from list_health_types."
                    ],
                    "days": [
                        "type": "integer",
                        "description": "How far back to look. Defaults to 90."
                    ]
                ] as [String: Any],
                "required": ["type"]
            ]
        ],
        [
            "name": "compare_health_types",
            "description": """
                Whether two types move together day to day — sleep against \
                step count, say. Reports the correlation with a confidence \
                interval computed on an autocorrelation-adjusted sample size, \
                because consecutive days are not independent evidence. Warns \
                when both series are trending, which produces strong \
                correlations between unrelated things. Never describe a \
                relationship this tool reports as undetectable, and never \
                describe any correlation as one type causing the other.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "first": ["type": "string", "description": "First HealthKit type identifier."],
                    "second": ["type": "string", "description": "Second HealthKit type identifier."],
                    "days": [
                        "type": "integer",
                        "description": "How far back to look. Defaults to 180."
                    ]
                ] as [String: Any],
                "required": ["first", "second"]
            ]
        ],
        [
            "name": "find_health_anomalies",
            "description": """
                Days that stand out from what is usual for this person, using \
                the median and median absolute deviation so one bad day cannot \
                hide the others. Days with too few records to judge — the \
                watch was not worn — are reported separately as exactly that, \
                never as low readings. Do not report a day listed under low \
                coverage as an unusual measurement.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "The HealthKit type identifier, from list_health_types."
                    ],
                    "days": [
                        "type": "integer",
                        "description": "How far back to look. Defaults to 90."
                    ]
                ] as [String: Any],
                "required": ["type"]
            ]
        ],
        [
            "name": "list_mood_entries",
            "description": """
                State of Mind entries with their valence, how Health \
                classified the feeling, whether it was a momentary emotion or \
                a whole day's mood, and what the person attributed it to. \
                Mood also charts through aggregate_health_data and \
                analyse_health_trend as an ordinary type, so use those for \
                "is my mood declining"; use this when the labels and \
                associations matter.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "How far back to look. Defaults to 90."],
                    "limit": ["type": "integer", "description": "How many entries. Defaults to 100."]
                ] as [String: Any]
            ]
        ],
        [
            "name": "summarise_medication_adherence",
            "description": """
                Medication dose events per medicine, counted by status. Only \
                "taken" means the medicine was actually taken — skipped, \
                snoozed and never-answered are three different ways of not \
                taking it and are reported separately. Never collapse them \
                into a single adherence figure, and never treat a \
                never-answered dose as evidence either way.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "How far back to look. Defaults to 90."]
                ] as [String: Any]
            ]
        ],
        [
            "name": "list_workouts",
            "description": """
                Workouts with what Health computed about each one: average, \
                minimum and maximum heart rate, energy burned, distance, and \
                whatever else it measured. A multi-sport workout also reports \
                each leg separately, because an average across a swim, a ride \
                and a run describes none of them. This is the tool for "how \
                did that run go" and "what was my average heart rate on it".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "How far back to look. Defaults to 90."],
                    "limit": ["type": "integer", "description": "How many workouts. Defaults to 50."]
                ] as [String: Any]
            ]
        ],
        [
            "name": "list_electrocardiograms",
            "description": """
                Every ECG reading, newest first, with what the Watch \
                classified it as, the average heart rate, whether the person \
                reported symptoms, and whether the full waveform has arrived. \
                Use this for questions about ECGs; they are not ordinary \
                samples and do not appear in list_health_samples.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many readings to return. Defaults to 50."
                    ]
                ] as [String: Any]
            ]
        ],
        [
            "name": "get_electrocardiogram_voltages",
            "description": """
                The waveform of one ECG reading, as time/volt pairs. Says \
                explicitly whether the recording is complete: a waveform \
                assembled from pages that are still arriving is not the same \
                as a whole one, and must not be read as though it were. Large: \
                a thirty-second reading is roughly 15,000 points, so ask for a \
                limit unless the whole trace is genuinely needed.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "The reading's id, from list_electrocardiograms."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "How many points to return. Defaults to 500."
                    ]
                ] as [String: Any],
                "required": ["id"]
            ]
        ],
        [
            "name": "list_audiograms",
            "description": """
                Hearing tests, newest first, with the threshold measured at \
                each frequency for each ear. A clamped reading is reported as \
                a bound rather than a measurement.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many tests to return. Defaults to 20."
                    ]
                ] as [String: Any]
            ]
        ],
        [
            "name": "list_health_samples",
            "description": """
                Individual Health samples, newest first. Use only when single \
                readings matter; for trends use aggregate_health_data, which is \
                faster and reveals far less personal detail.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "description": "Optional type filter."],
                    "from": ["type": "string", "description": "ISO 8601 start, inclusive."],
                    "to": ["type": "string", "description": "ISO 8601 end, inclusive."],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum rows, capped at 1000. Defaults to 100."
                    ]
                ]
            ]
        ]
    ]
    }
}
