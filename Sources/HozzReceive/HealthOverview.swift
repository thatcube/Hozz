import Foundation
import HozzCore
import HozzStore

/// How many records the archive holds over time, across every type at once.
public struct ArchiveDensityColumn: Sendable, Hashable, Identifiable {
    public let index: Int
    public let start: Date
    public let end: Date
    public let recordCount: Int
    public let typeCount: Int

    public var id: Int { index }

    public init(
        index: Int,
        start: Date,
        end: Date,
        recordCount: Int,
        typeCount: Int
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.recordCount = recordCount
        self.typeCount = typeCount
    }
}

extension IngestStore {
    /// The shape of the whole archive over time.
    ///
    /// Worth a chart of its own rather than being hidden. A phone works back
    /// through years of history one type at a time, so an archive in progress is
    /// genuinely lopsided — dense where the sweep has been, thin at the edges —
    /// and someone looking at a sparse recent month deserves to see that it is
    /// the sweep's shape rather than a gap in their life.
    public func archiveDensity(plan: TimeBucketPlan) throws -> [ArchiveDensityColumn] {
        guard !plan.columns.isEmpty else {
            return []
        }
        let values = plan.columns.map { column in
            "(\(column.index),"
                + "'\(Timestamps.text(from: column.start))',"
                + "'\(Timestamps.text(from: column.end))')"
        }.joined(separator: ",")

        let counts = try database.query(
            """
            WITH b(idx, lo, hi) AS (VALUES \(values))
            SELECT b.idx, COUNT(*), COUNT(DISTINCT s.type)
              FROM b JOIN sample s
                ON s.start_date >= b.lo AND s.start_date < b.hi
             GROUP BY b.idx
            """
        ) { row in
            (
                index: Int(row.integer(0)),
                records: Int(row.integer(1)),
                types: Int(row.integer(2))
            )
        }
        let byIndex = Dictionary(uniqueKeysWithValues: counts.map { ($0.index, $0) })

        return plan.columns.map { column in
            let row = byIndex[column.index]
            return ArchiveDensityColumn(
                index: column.index,
                start: column.start,
                end: column.end,
                recordCount: row?.records ?? 0,
                typeCount: row?.types ?? 0
            )
        }
    }

    /// The earliest and latest sample in the whole archive.
    public func archiveSpan() throws -> (earliest: Date, latest: Date)? {
        let row = try database.query(
            "SELECT MIN(start_date), MAX(start_date) FROM sample",
            row: { ($0.optionalText(0), $0.optionalText(1)) }
        ).first
        guard let row,
              let earliest = row.0.flatMap(Timestamps.date(from:)),
              let latest = row.1.flatMap(Timestamps.date(from:)) else {
            return nil
        }
        return (earliest, latest)
    }

    /// One line about a type, for a dashboard row that has to fit on one.
    public struct MetricSnapshot: Sendable, Hashable, Identifiable {
        public let series: TypeSeries
        /// When this type was last seen at all, which may be long before the
        /// range being charted.
        public let latestOverall: Date?
        public let totalRecords: Int
        /// Whether `series` covers the range that was asked for, or an older
        /// window ending at this type's own last record.
        public let isFromEarlierWindow: Bool

        public var id: String { series.measure.type }

        public init(
            series: TypeSeries,
            latestOverall: Date?,
            totalRecords: Int,
            isFromEarlierWindow: Bool = false
        ) {
            self.series = series
            self.latestOverall = latestOverall
            self.totalRecords = totalRecords
            self.isFromEarlierWindow = isFromEarlierWindow
        }
    }

    /// Several types over the same columns, in one pass per type.
    ///
    /// Types absent from the archive are dropped rather than drawn empty: a row
    /// reading "—" for something the phone has never sent is noise, and the
    /// point of an overview is that everything on it means something.
    ///
    /// A type that *is* held but has nothing in the requested range falls back
    /// to the same-shaped window ending at its own most recent record, marked
    /// so the row can say when it is from. Without that, an archive still being
    /// swept opens on a screen where every line reads "nothing in range" — each
    /// one true, the whole thing useless, and the honest explanation nowhere in
    /// sight. A range picker cannot fix it either, because the types are not
    /// all stale by the same amount: this archive's newest step count is from
    /// January 2023 and its newest wrist temperature is from yesterday.
    public func snapshots(
        types: [String],
        plan: TimeBucketPlan
    ) throws -> [MetricSnapshot] {
        var results: [MetricSnapshot] = []
        for type in types {
            let bounds = try database.query(
                """
                SELECT MAX(start_date), COUNT(*) FROM sample WHERE type = ?
                """,
                [.text(type)],
                row: { ($0.optionalText(0), Int($0.integer(1))) }
            ).first ?? (nil, 0)
            guard bounds.1 > 0 else {
                continue
            }
            let latest = bounds.0.flatMap(Timestamps.date(from:))

            let asked = try series(type: type, plan: plan)
            if !asked.values.isEmpty || latest == nil {
                results.append(
                    MetricSnapshot(
                        series: asked,
                        latestOverall: latest,
                        totalRecords: bounds.1
                    )
                )
                continue
            }

            let fallbackPlan = TimeBucketPlan.trailing(
                max(plan.columns.count, 1),
                granularity: plan.granularity,
                endingAt: latest ?? .now,
                calendar: plan.calendar
            )
            let earlier = try series(type: type, plan: fallbackPlan)
            results.append(
                MetricSnapshot(
                    series: earlier.values.isEmpty ? asked : earlier,
                    latestOverall: latest,
                    totalRecords: bounds.1,
                    isFromEarlierWindow: !earlier.values.isEmpty
                )
            )
        }
        return results
    }
}

/// The types worth putting on an overview, grouped the way a person thinks
/// about them rather than the way HealthKit names them.
public enum HealthDomain: String, CaseIterable, Sendable, Identifiable {
    case activity = "Activity"
    case heart = "Heart"
    case sleep = "Sleep & recovery"
    case body = "Body"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .activity: "figure.walk"
        case .heart: "heart"
        case .sleep: "moon.zzz"
        case .body: "figure.stand"
        }
    }

    /// Ordered by what someone looks at first, not alphabetically.
    public var types: [String] {
        switch self {
        case .activity:
            [
                "HKQuantityTypeIdentifierStepCount",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                "HKQuantityTypeIdentifierAppleExerciseTime",
                "HKCategoryTypeIdentifierAppleStandHour",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                "HKQuantityTypeIdentifierDistanceCycling",
                "HKQuantityTypeIdentifierFlightsClimbed"
            ]
        case .heart:
            [
                "HKQuantityTypeIdentifierRestingHeartRate",
                "HKQuantityTypeIdentifierHeartRate",
                "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                "HKQuantityTypeIdentifierWalkingHeartRateAverage",
                "HKQuantityTypeIdentifierVO2Max",
                "HKQuantityTypeIdentifierOxygenSaturation",
                "HKQuantityTypeIdentifierRespiratoryRate"
            ]
        case .sleep:
            [
                "HKCategoryTypeIdentifierSleepAnalysis",
                "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
                "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",
                "HKCategoryTypeIdentifierMindfulSession",
                "HKQuantityTypeIdentifierTimeInDaylight"
            ]
        case .body:
            [
                "HKQuantityTypeIdentifierBodyMass",
                "HKQuantityTypeIdentifierBodyFatPercentage",
                "HKQuantityTypeIdentifierLeanBodyMass",
                "HKQuantityTypeIdentifierBodyMassIndex",
                "HKQuantityTypeIdentifierBloodPressureSystolic",
                "HKQuantityTypeIdentifierBloodPressureDiastolic",
                "HKQuantityTypeIdentifierBloodGlucose"
            ]
        }
    }
}
