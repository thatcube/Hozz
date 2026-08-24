import Foundation
import HealthKit
import HozzHealth

/// Reads Health for the dashboard.
///
/// The phone has no copy of Health's history to draw from — `HozzStore` holds
/// cursors, coverage and a bounded spool, and keeping a second copy of years
/// of samples on the phone is a design change rather than a convenience. So
/// the charts read Health directly, every time they are shown.
///
/// That makes the shape of the reads matter. A year of heart rate is tens of
/// thousands of samples, and fetching them to add up on the main actor is how
/// a chart becomes a stutter. Every quantity series here is reduced by
/// HealthKit itself through `HKStatisticsCollectionQuery`, which returns one
/// figure per bucket — twelve numbers for a year, not fifty thousand.
///
/// Nothing is written. Nothing leaves the device.
actor HealthMetricReader {
    // Safe to share: `HKHealthStore` documents its queries as usable from any
    // thread, and this type only ever executes them. The same reasoning the
    // export backends are written under.
    // Reachable from the workout and electrocardiogram reads in
    // WorkoutAndECGReading.swift, which extend this actor.
    nonisolated(unsafe) let healthStore: HKHealthStore
    private let calendar: Calendar

    /// The calendar the date maths in extensions of this actor uses.
    var calendarForQueries: Calendar { calendar }

    /// - Note: The calendar is deliberately not injectable.
    ///   `HKStatisticsCollectionQuery` computes its own intervals with the
    ///   system calendar and cannot be told to use another, so a reader
    ///   bucketing on a different one would put the two chains on different
    ///   boundaries and the mapping between them would stop being one to one.
    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.calendar = .current
    }

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Whether Hozz has already put the Health permission sheet in front of
    /// this person.
    ///
    /// This is the only authorization question HealthKit answers honestly for
    /// reads. Whether a *type* was allowed is deliberately not revealed — a
    /// declined type reads as empty, exactly like one with no data — so
    /// nothing here ever claims a type was granted.
    func hasBeenAsked(for metrics: [DashboardMetric]) async -> Bool {
        let types = readTypes(for: metrics)
        guard !types.isEmpty else {
            return true
        }
        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(
                toShare: [],
                read: types
            ) { status, _ in
                continuation.resume(returning: status == .unnecessary)
            }
        }
    }

    private nonisolated func readTypes(for metrics: [DashboardMetric]) -> Set<HKObjectType> {        var types: Set<HKObjectType> = []
        for metric in metrics {
            switch metric.kind {
            case .sleep:
                if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                    types.insert(sleep)
                }
            case .quantity(let identifier):
                if let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
                ) {
                    types.insert(type)
                }
            }
        }
        return types
    }

    /// Asks for read access to the types the dashboard draws.
    ///
    /// HealthKit answers `success` once the sheet has been dealt with, whatever
    /// the person chose. It is not a statement that anything was granted, and
    /// nothing here treats it as one.
    func requestAccess(to metrics: [DashboardMetric]) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthMetricError.healthUnavailable
        }
        let types = readTypes(for: metrics)
        guard !types.isEmpty else {
            return
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            healthStore.requestAuthorization(toShare: [], read: types) { _, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Series

    /// Samples whose *start* falls inside the range.
    ///
    /// `.strictStartDate` is what makes HealthKit agree with this app about
    /// which day a sample belongs to. Without it a sample overlapping a
    /// boundary is returned for both days, and the same reading is counted
    /// twice.
    ///
    /// Built fresh at each call site rather than made once and passed around,
    /// because `NSPredicate` is not `Sendable` and may not cross into a query
    /// callback.
    nonisolated static func rangePredicate(from start: Date, to end: Date) -> NSPredicate {
        HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
    }

    func series(
        for metric: DashboardMetric,
        range: MetricRange,
        now: Date = .now
    ) async throws -> MetricSeries {
        let intervals = MetricBucketing.buckets(
            for: range,
            endingAt: now,
            calendar: calendar
        )
        guard let first = intervals.first, let last = intervals.last else {
            return MetricSeries(
                buckets: [],
                unit: nil,
                aggregation: .total,
                hasUnitConflict: false,
                containsAggregatedReadings: false
            )
        }

        switch metric.kind {
        case .sleep:
            return try await sleepSeries(intervals: intervals, from: first.start, to: last.end)
        case .quantity(let identifier):
            guard let type = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
            ) else {
                throw HealthMetricError.unknownType(identifier)
            }
            let reading = DashboardMetrics.reading(for: metric)
                ?? DashboardMetrics.Reading(.count())
            let aggregation = MetricAggregation(type.aggregationStyle)
            return try await quantitySeries(
                type: type,
                reading: reading,
                aggregation: aggregation,
                intervals: intervals,
                range: range
            )
        }
    }

    private func quantitySeries(
        type: HKQuantityType,
        reading: DashboardMetrics.Reading,
        aggregation: MetricAggregation,
        intervals: [DateInterval],
        range: MetricRange
    ) async throws -> MetricSeries {
        let unit = reading.unit
        let scale = reading.scale
        guard let first = intervals.first, let last = intervals.last else {
            throw HealthMetricError.emptyRange
        }

        // `.strictStartDate` keeps HealthKit's idea of which samples are in
        // range identical to this app's: a sample belongs to the bucket its
        // start falls in. Without it an overlapping sample is returned for
        // both, and the two layers disagree about the same day.
        //
        // The predicate is rebuilt inside each query closure rather than made
        // once and captured: `NSPredicate` is not `Sendable`, and building it
        // twice costs nothing next to the query it describes.
        let rangeStart = first.start
        let rangeEnd = last.end

        var components = DateComponents()
        switch range.bucketUnit {
        case .month: components.month = 1
        default: components.day = 1
        }

        let options = aggregation.statisticsOptions
        let bucketValues = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[StatisticsBucket], any Error>) in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: Self.rangePredicate(from: rangeStart, to: rangeEnd),
                options: options,
                anchorDate: rangeStart,
                intervalComponents: components
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                // Reduced to `Sendable` values inside the callback so no
                // `HKStatistics` ever leaves HealthKit's queue.
                var gathered: [StatisticsBucket] = []
                collection.enumerateStatistics(from: rangeStart, to: rangeEnd) { statistics, _ in
                    let quantity: HKQuantity? = switch aggregation {
                    case .total: statistics.sumQuantity()
                    case .average: statistics.averageQuantity()
                    }
                    guard let quantity else {
                        return
                    }
                    gathered.append(
                        StatisticsBucket(
                            start: statistics.startDate,
                            value: quantity.doubleValue(for: unit) * scale,
                            minimum: statistics.minimumQuantity()
                                .map { $0.doubleValue(for: unit) * scale },
                            maximum: statistics.maximumQuantity()
                                .map { $0.doubleValue(for: unit) * scale }
                        )
                    )
                }
                continuation.resume(returning: gathered)
            }
            healthStore.execute(query)
        }

        let overall = try await wholeRange(
            type: type,
            unit: unit,
            scale: scale,
            aggregation: aggregation,
            from: rangeStart,
            to: rangeEnd
        )

        // Merged rather than assigned. HealthKit walks its own intervals
        // forward from the anchor with the system calendar, so on the one day
        // a year a local day is twenty-five hours long it can return two
        // statistics whose starts both fall inside a single bucket here.
        // Overwriting would drop one of them silently — from the bar and, for
        // a cumulative type, from the range total with it.
        var byIndex: [Int: StatisticsBucket] = [:]
        for bucket in bucketValues {
            guard let index = MetricBucketing.index(of: bucket.start, in: intervals) else {
                continue
            }
            byIndex[index] = byIndex[index].map { $0.merged(with: bucket, using: aggregation) }
                ?? bucket
        }

        let buckets = intervals.enumerated().map { index, interval in
            guard let found = byIndex[index] else {
                return MetricBucket(
                    interval: interval,
                    value: nil,
                    minimum: nil,
                    maximum: nil,
                    readingCount: 0,
                    sampleCount: 0
                )
            }
            return MetricBucket(
                interval: interval,
                value: found.value,
                minimum: found.minimum,
                maximum: found.maximum,
                // HealthKit does not say how many readings a statistic stands
                // for, so nothing is claimed. The whole-range figure above is
                // what the headline is taken from instead.
                readingCount: 0,
                sampleCount: 1
            )
        }

        return MetricSeries(
            buckets: buckets,
            unit: unit.unitString,
            aggregation: aggregation,
            hasUnitConflict: false,
            containsAggregatedReadings: false,
            overall: overall
        )
    }

    /// The range reduced in one go by HealthKit, which can see every reading.
    private func wholeRange(
        type: HKQuantityType,
        unit: HKUnit,
        scale: Double,
        aggregation: MetricAggregation,
        from start: Date,
        to end: Date
    ) async throws -> MetricOverall? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<MetricOverall?, any Error>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: Self.rangePredicate(from: start, to: end),
                options: aggregation.statisticsOptions
            ) { _, statistics, error in
                if let error {
                    // No data at all is reported as an error by HealthKit for
                    // some types. That is not a failure worth surfacing — it
                    // is the empty answer — so it becomes "nothing" here and
                    // the buckets say the same thing.
                    //
                    // The domain is checked as well as the code, following
                    // HealthKitCharacteristicsReader. Code 7 exists in several
                    // domains, and swallowing a Cocoa or POSIX error as "no
                    // data" would leave the range headline quietly absent over
                    // a chart that is visibly drawing.
                    let nsError = error as NSError
                    if nsError.domain == HKError.errorDomain,
                       nsError.code == HKError.errorNoData.rawValue {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: HealthKitFailure.classify(error))
                    }
                    return
                }
                guard let statistics else {
                    continuation.resume(returning: nil)
                    return
                }
                let quantity: HKQuantity? = switch aggregation {
                case .total: statistics.sumQuantity()
                case .average: statistics.averageQuantity()
                }
                guard let quantity else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: MetricOverall(
                        value: quantity.doubleValue(for: unit) * scale,
                        minimum: statistics.minimumQuantity()
                            .map { $0.doubleValue(for: unit) * scale },
                        maximum: statistics.maximumQuantity()
                            .map { $0.doubleValue(for: unit) * scale }
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Sleep

    /// Sleep is a category type, so there is no statistics query for it: the
    /// stretches have to be read and measured. They are bounded by the range
    /// asked for, which keeps even a year to a few thousand short samples.
    private func sleepSeries(
        intervals: [DateInterval],
        from start: Date,
        to end: Date
    ) async throws -> MetricSeries {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthMetricError.unknownType(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
        }

        // Widened backwards by a day so a night that began before the range
        // still contributes the part of it that falls inside.
        let searchStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(
            withStart: searchStart,
            end: end,
            options: []
        )

        let asleep = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[DateInterval], any Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                    return
                }
                let stretches = (samples as? [HKCategorySample] ?? [])
                    .filter { Self.isAsleep($0.value) }
                    .compactMap { sample -> DateInterval? in
                        guard sample.endDate > sample.startDate else {
                            return nil
                        }
                        return DateInterval(start: sample.startDate, end: sample.endDate)
                    }
                continuation.resume(returning: stretches)
            }
            healthStore.execute(query)
        }

        let readings = SleepAttribution.readings(from: asleep, calendar: calendar)
        return MetricAggregator.aggregate(readings, into: intervals, using: .total)
    }

    /// Whether a sleep sample's value means the person was actually asleep.
    ///
    /// In bed is not asleep and awake is certainly not, so neither counts.
    /// Reporting time in bed as time slept is the most common way a sleep
    /// figure flatters someone.
    nonisolated static func isAsleep(_ value: Int) -> Bool {        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else {
            return false
        }
        switch stage {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
            return true
        case .inBed, .awake:
            return false
        @unknown default:
            // A stage this build has never heard of is not counted as sleep.
            // Guessing would inflate the figure, and inflating a health number
            // is the wrong direction to be wrong in.
            return false
        }
    }
}

/// A bucket as HealthKit reduced it, flattened to values that may cross back
/// out of a query callback.
private struct StatisticsBucket: Sendable {
    let start: Date
    let value: Double
    let minimum: Double?
    let maximum: Double?

    /// Two statistics that landed in the same bucket, combined the way that
    /// bucket's type allows.
    ///
    /// Sums add exactly. Averages cannot be combined exactly without knowing
    /// how many readings each stands for, and HealthKit does not say — so the
    /// two are meaned, which is approximate. That approximation only ever
    /// reaches a drawn bar: every reported statistic for a measured type comes
    /// from the whole-range query, which sees the readings themselves.
    func merged(with other: StatisticsBucket, using aggregation: MetricAggregation) -> Self {
        StatisticsBucket(
            start: Swift.min(start, other.start),
            value: aggregation == .total ? value + other.value : (value + other.value) / 2,
            minimum: [minimum, other.minimum].compactMap { $0 }.min(),
            maximum: [maximum, other.maximum].compactMap { $0 }.max()
        )
    }
}
enum HealthMetricError: Error, LocalizedError, Equatable {
    case unknownType(String)
    case emptyRange
    case healthUnavailable
    case waveformUnreadable

    var errorDescription: String? {
        switch self {
        case .unknownType(let identifier):
            "This version of iOS does not know the type \(identifier)."
        case .emptyRange:
            "That range covers no time at all."
        case .healthUnavailable:
            "Apple Health is unavailable or restricted on this device."
        case .waveformUnreadable:
            "Health did not return the readings behind this recording."
        }
    }
}
