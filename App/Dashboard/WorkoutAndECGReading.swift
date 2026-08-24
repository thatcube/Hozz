import Foundation
import HealthKit
import HozzDeliver
import HozzHealth

// MARK: - Workouts

/// One workout, reduced to what a view needs and nothing that could not cross
/// out of a HealthKit callback.
struct WorkoutSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let activityName: String
    let start: Date
    let end: Date
    let duration: TimeInterval
    let energyKilocalories: Double?
    let distanceMeters: Double?
    let averageHeartRate: Double?
    let minimumHeartRate: Double?
    let maximumHeartRate: Double?
    /// The legs of a multi-sport workout.
    ///
    /// Present only when there is genuinely more than one, because an average
    /// heart rate across a swim, a ride and a run describes none of the three
    /// and a single-sport workout has nothing to break out.
    let legs: [WorkoutLeg]

    var isMultiSport: Bool { legs.count > 1 }
}

struct WorkoutLeg: Identifiable, Sendable, Equatable {
    let id: UUID
    let activityName: String
    let start: Date
    let end: Date
    let duration: TimeInterval
    let energyKilocalories: Double?
    let distanceMeters: Double?
    let averageHeartRate: Double?
    let minimumHeartRate: Double?
    let maximumHeartRate: Double?
}

// MARK: - Electrocardiograms

/// A recording's headline facts, without its waveform.
struct ECGSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let recordedAt: Date
    let classification: String
    let symptoms: String
    let averageHeartRate: Double?
    let samplingFrequencyHertz: Double?
    /// How many voltage readings HealthKit says the recording holds. The
    /// number a waveform has to match before it may be called whole.
    let expectedMeasurementCount: Int
    let duration: TimeInterval?
}

/// A recording's trace.
struct ECGWaveform: Sendable, Equatable {
    let sampleID: UUID
    let points: [ECGPoint]
    /// What HealthKit said the recording contains.
    let expectedCount: Int
    let samplingFrequencyHertz: Double?

    /// Whether every reading the recording claims to hold actually arrived.
    ///
    /// A trace assembled from a read that stopped early is not the same object
    /// as a whole one, and drawing it as though it were is how a gap becomes a
    /// flat line through the middle of someone's heartbeat. Nothing may
    /// present this trace without consulting this first.
    var isComplete: Bool {
        expectedCount > 0 && points.count >= expectedCount
    }
}

struct ECGPoint: Sendable, Equatable {
    let secondsSinceStart: TimeInterval
    let microvolts: Double
}

// MARK: - Decimation

/// Shrinking a trace to something drawable without losing what matters in it.
enum ECGDecimation {
    /// Reduces a trace to at most `buckets` columns, keeping the lowest and
    /// highest reading in each.
    ///
    /// Taking every nth reading — the obvious way — is wrong here in a
    /// specific and dangerous way. A QRS complex is a spike a few readings
    /// wide, and sampling past it flattens the one feature of the trace anyone
    /// looks at. Keeping both extremes of each column preserves the envelope,
    /// so a spike stays a spike however far the trace is shrunk.
    static func envelope(_ points: [ECGPoint], buckets: Int) -> [ECGEnvelope] {
        guard buckets > 0, !points.isEmpty else {
            return []
        }
        guard points.count > buckets else {
            return points.map {
                ECGEnvelope(
                    secondsSinceStart: $0.secondsSinceStart,
                    low: $0.microvolts,
                    high: $0.microvolts
                )
            }
        }

        let perBucket = Double(points.count) / Double(buckets)
        var result: [ECGEnvelope] = []
        result.reserveCapacity(buckets)

        for bucket in 0..<buckets {
            let lower = Int(Double(bucket) * perBucket)
            let upper = min(points.count, Int(Double(bucket + 1) * perBucket))
            guard lower < upper else {
                continue
            }
            var low = points[lower].microvolts
            var high = low
            for index in lower..<upper {
                let value = points[index].microvolts
                low = Swift.min(low, value)
                high = Swift.max(high, value)
            }
            result.append(
                ECGEnvelope(
                    secondsSinceStart: points[lower].secondsSinceStart,
                    low: low,
                    high: high
                )
            )
        }
        return result
    }
}

struct ECGEnvelope: Sendable, Equatable, Identifiable {
    let secondsSinceStart: TimeInterval
    let low: Double
    let high: Double

    var id: TimeInterval { secondsSinceStart }
}

// MARK: - Reading them

extension HealthMetricReader {
    /// Workouts, newest first.
    func workouts(inLast days: Int, limit: Int = 200) async throws -> [WorkoutSummary] {
        let end = Date()
        let start = calendarForQueries.date(byAdding: .day, value: -days, to: end) ?? end

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[WorkoutSummary], any Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                limit: limit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                    return
                }
                // Flattened inside the callback: no `HKWorkout` leaves it.
                let summaries = (samples as? [HKWorkout] ?? []).map(Self.summarise)
                continuation.resume(returning: summaries)
            }
            healthStore.execute(query)
        }
    }

    func workoutCount(inLast days: Int) async throws -> Int {
        try await workouts(inLast: days, limit: HKObjectQueryNoLimit).count
    }

    nonisolated static func summarise(_ workout: HKWorkout) -> WorkoutSummary {
        let heart = heartRateFigures(workout.allStatistics)
        let legs: [WorkoutLeg] = workout.workoutActivities.map { activity in
            let legHeart = heartRateFigures(activity.allStatistics)
            let end = activity.endDate ?? workout.endDate
            return WorkoutLeg(
                id: activity.uuid,
                activityName: WorkoutActivityNames.label(
                    for: Int(activity.workoutConfiguration.activityType.rawValue)
                ),
                start: activity.startDate,
                end: end,
                duration: end.timeIntervalSince(activity.startDate),
                energyKilocalories: sum(
                    activity.allStatistics,
                    identifier: .activeEnergyBurned,
                    unit: .kilocalorie()
                ),
                distanceMeters: distance(activity.allStatistics),
                averageHeartRate: legHeart.average,
                minimumHeartRate: legHeart.minimum,
                maximumHeartRate: legHeart.maximum
            )
        }

        return WorkoutSummary(
            id: workout.uuid,
            activityName: WorkoutActivityNames.label(
                for: Int(workout.workoutActivityType.rawValue)
            ),
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            energyKilocalories: sum(
                workout.allStatistics,
                identifier: .activeEnergyBurned,
                unit: .kilocalorie()
            ),
            distanceMeters: distance(workout.allStatistics),
            averageHeartRate: heart.average,
            minimumHeartRate: heart.minimum,
            maximumHeartRate: heart.maximum,
            // One leg is not a multi-sport workout, it is the workout. Keeping
            // it would put an identical duplicate under every ordinary run.
            legs: legs.count > 1 ? legs : []
        )
    }

    private nonisolated static func heartRateFigures(
        _ statistics: [HKQuantityType: HKStatistics]
    ) -> (average: Double?, minimum: Double?, maximum: Double?) {
        guard
            let type = HKObjectType.quantityType(forIdentifier: .heartRate),
            let found = statistics[type]
        else {
            return (nil, nil, nil)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return (
            found.averageQuantity()?.doubleValue(for: unit),
            found.minimumQuantity()?.doubleValue(for: unit),
            found.maximumQuantity()?.doubleValue(for: unit)
        )
    }

    private nonisolated static func sum(
        _ statistics: [HKQuantityType: HKStatistics],
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) -> Double? {
        guard
            let type = HKObjectType.quantityType(forIdentifier: identifier),
            let found = statistics[type]
        else {
            return nil
        }
        return found.sumQuantity()?.doubleValue(for: unit)
    }

    /// Distance, whichever kind this workout recorded.
    ///
    /// A swim reports swimming distance and a ride cycling distance, so asking
    /// only for walking distance reports nothing for most workouts.
    private nonisolated static func distance(
        _ statistics: [HKQuantityType: HKStatistics]
    ) -> Double? {
        var identifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports
        ]
        if #available(iOS 18.0, *) {
            identifiers.append(contentsOf: [.distancePaddleSports, .distanceRowing])
        }
        for identifier in identifiers {
            if let value = sum(statistics, identifier: identifier, unit: .meter()), value > 0 {
                return value
            }
        }
        return nil
    }

    // MARK: - ECG

    func electrocardiograms(limit: Int = 100) async throws -> [ECGSummary] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[ECGSummary], any Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.electrocardiogramType(),
                predicate: nil,
                limit: limit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                    return
                }
                let readings = (samples as? [HKElectrocardiogram] ?? []).map(Self.summarise)
                continuation.resume(returning: readings)
            }
            healthStore.execute(query)
        }
    }

    func electrocardiogramCount() async throws -> Int {
        try await electrocardiograms(limit: HKObjectQueryNoLimit).count
    }

    nonisolated static func summarise(_ sample: HKElectrocardiogram) -> ECGSummary {
        let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
        return ECGSummary(
            id: sample.uuid,
            recordedAt: sample.startDate,
            classification: describe(sample.classification),
            symptoms: describe(sample.symptomsStatus),
            averageHeartRate: sample.averageHeartRate?.doubleValue(for: beatsPerMinute),
            samplingFrequencyHertz: sample.samplingFrequency?.doubleValue(for: .hertz()),
            expectedMeasurementCount: sample.numberOfVoltageMeasurements,
            duration: sample.endDate.timeIntervalSince(sample.startDate)
        )
    }

    /// The trace of one recording.
    ///
    /// The reading either finishes or it does not, and the difference is
    /// carried out rather than smoothed over: `ECGWaveform.isComplete`
    /// compares what arrived against what HealthKit said the recording holds,
    /// and a partial trace is never presented as a whole one.
    func waveform(for summary: ECGSummary) async throws -> ECGWaveform {
        let sample = try await electrocardiogramSample(with: summary.id)
        let expected = summary.expectedMeasurementCount

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ECGWaveform, any Error>) in
            var points: [ECGPoint] = []
            points.reserveCapacity(max(0, expected))
            var finished = false

            let query = HKElectrocardiogramQuery(sample) { _, result in
                // `finished` guards the continuation: HealthKit calls this
                // handler once per reading, and resuming twice traps.
                guard !finished else {
                    return
                }
                switch result {
                case .measurement(let measurement):
                    if let quantity = measurement.quantity(
                        for: .appleWatchSimilarToLeadI
                    ) {
                        points.append(
                            ECGPoint(
                                secondsSinceStart: measurement.timeSinceSampleStart,
                                microvolts: quantity.doubleValue(
                                    for: .voltUnit(with: .micro)
                                )
                            )
                        )
                    }
                case .done:
                    finished = true
                    continuation.resume(
                        returning: ECGWaveform(
                            sampleID: summary.id,
                            points: points,
                            expectedCount: expected,
                            samplingFrequencyHertz: summary.samplingFrequencyHertz
                        )
                    )
                case .error(let error):
                    finished = true
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                @unknown default:
                    finished = true
                    continuation.resume(throwing: HealthMetricError.waveformUnreadable)
                }
            }
            healthStore.execute(query)
        }
    }

    private func electrocardiogramSample(
        with id: UUID
    ) async throws -> HKElectrocardiogram {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKElectrocardiogram, any Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.electrocardiogramType(),
                predicate: HKQuery.predicateForObject(with: id),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitFailure.classify(error))
                    return
                }
                guard let sample = (samples as? [HKElectrocardiogram])?.first else {
                    continuation.resume(throwing: HealthMetricError.waveformUnreadable)
                    return
                }
                continuation.resume(returning: sample)
            }
            healthStore.execute(query)
        }
    }

    private nonisolated static func describe(
        _ value: HKElectrocardiogram.Classification
    ) -> String {
        switch value {
        case .notSet: "Not set"
        case .sinusRhythm: "Sinus rhythm"
        case .atrialFibrillation: "Atrial fibrillation"
        case .inconclusiveLowHeartRate: "Inconclusive — low heart rate"
        case .inconclusiveHighHeartRate: "Inconclusive — high heart rate"
        case .inconclusivePoorReading: "Inconclusive — poor reading"
        case .inconclusiveOther: "Inconclusive"
        case .unrecognized: "Unrecognised"
        @unknown default: "Not recognised by this version of Hozz"
        }
    }

    private nonisolated static func describe(
        _ value: HKElectrocardiogram.SymptomsStatus
    ) -> String {
        switch value {
        case .notSet: "Not recorded"
        case .none: "No symptoms reported"
        case .present: "Symptoms reported"
        @unknown default: "Not recognised by this version of Hozz"
        }
    }
}
