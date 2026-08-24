import Foundation
import HealthKit
import HozzUI

/// Which metrics the dashboard offers, and — more importantly — where the
/// decision about how to combine them comes from.
///
/// The combining rule is read off HealthKit's own classification of the type
/// rather than kept as a list here. A hand-maintained list of "these ones add
/// up" is a list that goes stale the first time Apple adds a type, and the
/// failure mode is silent: a measured quantity quietly summed into a large,
/// confident, meaningless number.

// MARK: - Total or average, decided by HealthKit

extension MetricAggregation {
    /// Taken from `HKQuantityType.aggregationStyle`, which is HealthKit's own
    /// statement about what the type is.
    ///
    /// Everything that is not explicitly cumulative averages. That default is
    /// the safe direction on purpose: a new discrete style Apple adds later
    /// falls into `.average` and is merely conservative, whereas defaulting the
    /// other way would sum a measurement the first time it appeared.
    init(_ style: HKQuantityAggregationStyle) {
        switch style {
        case .cumulative:
            self = .total
        default:
            self = .average
        }
    }

    /// The statistics HealthKit is asked for.
    ///
    /// This mapping is not cosmetic. Asking for `.cumulativeSum` on a discrete
    /// type raises an exception rather than returning a wrong number, and
    /// asking for `.discreteAverage` on a cumulative one is refused the same
    /// way, so the pairing has to follow the aggregation and nothing else.
    var statisticsOptions: HKStatisticsOptions {
        switch self {
        case .total:
            [.cumulativeSum]
        case .average:
            [.discreteAverage, .discreteMin, .discreteMax]
        }
    }
}

// MARK: - The metrics on offer

/// One thing the dashboard can draw.
struct DashboardMetric: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A quantity type, read through HealthKit's statistics collection.
        case quantity(String)
        /// Sleep, which is a category type and is measured in time asleep
        /// rather than in a value on the sample.
        case sleep
    }

    let kind: Kind
    let title: String
    /// What one unit is called, in the plural, for a caption.
    let unitLabel: String
    let icon: HozzIcon
    /// How many decimal places the headline deserves. A step count with a
    /// decimal point is noise; a body mass without one is a lie by rounding.
    let fractionDigits: Int
    /// A rule this metric is filed under, said where someone can read it.
    ///
    /// Some metrics need a choice made before they can be drawn at all, and a
    /// choice a reader cannot see looks like a bug when it surprises them. The
    /// rule belongs on the screen beside the number, not only in a comment in
    /// the source — otherwise the only people who can tell the number is
    /// correct are the people who wrote it.
    var note: String? = nil

    var id: String {
        switch kind {
        case .quantity(let identifier): identifier
        case .sleep: "hozz.sleep"
        }
    }

    var quantityIdentifier: HKQuantityTypeIdentifier? {
        switch kind {
        case .quantity(let identifier): HKQuantityTypeIdentifier(rawValue: identifier)
        case .sleep: nil
        }
    }
}

enum DashboardMetrics {
    private static var usesImperial: Bool {
        Locale.current.measurementSystem == .us
    }

    static var distanceUnitLabel: String { usesImperial ? "mi" : "km" }
    static var massUnitLabel: String { usesImperial ? "lb" : "kg" }

    /// The unit a metric is read in, together with what its values must be
    /// multiplied by to mean what the label says.
    ///
    /// The scale exists because of one trap. HealthKit's percent unit is a
    /// fraction, not a percentage — the header says `% (0.0 - 1.0)` — so a
    /// blood oxygen of 98% comes back as `0.98`. Printed beside a "%" label
    /// that reads as "1.0 %", which is both alarming and wrong. Carrying the
    /// unit and its scale in one value is what stops the two from drifting
    /// apart, since they are used in different places.
    struct Reading: Sendable {
        let unit: HKUnit
        let scale: Double

        init(_ unit: HKUnit, scale: Double = 1) {
            self.unit = unit
            self.scale = scale
        }
    }

    /// The unit a metric is read and drawn in.
    ///
    /// Chosen once, here, so a series can never mix units — the aggregator
    /// refuses to add across units, and this is what makes that a guard rather
    /// than an everyday occurrence.
    static func reading(for metric: DashboardMetric) -> Reading? {
        switch metric.kind {
        case .sleep:
            return Reading(.hour())
        case .quantity(let identifier):
            switch HKQuantityTypeIdentifier(rawValue: identifier) {
            case .stepCount, .flightsClimbed:
                return Reading(.count())
            case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed:
                return Reading(.kilocalorie())
            case .distanceWalkingRunning, .distanceCycling, .distanceSwimming:
                return Reading(usesImperial ? .mile() : .meterUnit(with: .kilo))
            case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate:
                return Reading(.count().unitDivided(by: .minute()))
            case .heartRateVariabilitySDNN:
                return Reading(.secondUnit(with: .milli))
            case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage:
                // Read as the fraction HealthKit stores, shown as the
                // percentage everyone means by it.
                return Reading(.percent(), scale: 100)
            case .bodyMass, .leanBodyMass:
                return Reading(usesImperial ? .pound() : .gramUnit(with: .kilo))
            case .height:
                return Reading(usesImperial ? .inch() : .meterUnit(with: .centi))
            case .appleExerciseTime, .appleStandTime:
                return Reading(.minute())
            case .vo2Max:
                return Reading(HKUnit(from: "ml/kg*min"))
            case .bodyTemperature, .basalBodyTemperature:
                return Reading(usesImperial ? .degreeFahrenheit() : .degreeCelsius())
            case .bloodGlucose:
                return Reading(HKUnit(from: "mg/dL"))
            case .environmentalAudioExposure, .headphoneAudioExposure:
                return Reading(.decibelAWeightedSoundPressureLevel())
            default:
                // Anything not named above has no unit chosen here, and the
                // caller reads it in HealthKit's own canonical one.
                return nil
            }
        }
    }

    /// The metrics the overview leads with, in the order they are shown.
    ///
    /// A short list on purpose. The overview is meant to be worth opening,
    /// which means a handful of things read at a glance rather than a wall of
    /// every type Health knows about — those are reachable from the browse
    /// list instead.
    static let headline: [DashboardMetric] = [
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.stepCount.rawValue),
            title: "Steps",
            unitLabel: "steps",
            icon: .footsteps,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue),
            title: "Active energy",
            unitLabel: "kcal",
            icon: .flame,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.restingHeartRate.rawValue),
            title: "Resting heart rate",
            unitLabel: "bpm",
            icon: .heart,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .sleep,
            title: "Sleep",
            unitLabel: "hours",
            icon: .bed,
            fractionDigits: 1,
            note: """
            A night counts towards the day you woke up. Overlapping records \
            are counted once.
            """
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue),
            title: "Walking + running",
            unitLabel: distanceUnitLabel,
            icon: .run,
            fractionDigits: 1
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.appleExerciseTime.rawValue),
            title: "Exercise",
            unitLabel: "min",
            icon: .activity,
            fractionDigits: 0
        )
    ]

    /// Everything else worth browsing to, beyond the headline set.
    static let browsable: [DashboardMetric] = [
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.heartRate.rawValue),
            title: "Heart rate",
            unitLabel: "bpm",
            icon: .heart,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue),
            title: "Heart rate variability",
            unitLabel: "ms",
            icon: .activity,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue),
            title: "Walking heart rate",
            unitLabel: "bpm",
            icon: .heart,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.respiratoryRate.rawValue),
            title: "Respiratory rate",
            unitLabel: "br/min",
            icon: .activity,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.oxygenSaturation.rawValue),
            title: "Blood oxygen",
            unitLabel: "%",
            icon: .droplet,
            fractionDigits: 1
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.vo2Max.rawValue),
            title: "Cardio fitness",
            unitLabel: "ml/kg·min",
            icon: .activity,
            fractionDigits: 1
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.bodyMass.rawValue),
            title: "Body mass",
            unitLabel: massUnitLabel,
            icon: .scale,
            fractionDigits: 1
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.flightsClimbed.rawValue),
            title: "Flights climbed",
            unitLabel: "flights",
            icon: .activity,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.basalEnergyBurned.rawValue),
            title: "Resting energy",
            unitLabel: "kcal",
            icon: .flame,
            fractionDigits: 0
        ),
        DashboardMetric(
            kind: .quantity(HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue),
            title: "Environmental sound",
            unitLabel: "dBA",
            icon: .activity,
            fractionDigits: 0
        )
    ]

    static let all: [DashboardMetric] = headline + browsable
}

// MARK: - Sleep

/// How a stretch of sleep is filed under a day, and how overlapping stretches
/// are counted once.
///
/// Both of these are places where the obvious implementation is wrong in a way
/// that looks right.
enum SleepAttribution {
    /// Sleep starting at or after this hour belongs to the following day.
    ///
    /// Without a rule like this, a night beginning at 23:30 is filed under the
    /// evening it started and the morning it ended, splitting one night across
    /// two bars and halving both. Six in the evening is the boundary Health
    /// itself presents sleep on, and it puts a whole night — and an afternoon
    /// nap — where a person would look for it.
    ///
    /// This rule is stated on screen, not only here: `DashboardMetrics.sleep`
    /// carries a note the detail view prints under the chart. A filing rule a
    /// reader cannot see makes a correct number look like a mistake. Changing
    /// the hour means changing that sentence too.
    static let dayBoundaryHour = 18

    /// The day a stretch of sleep counts towards.
    static func day(
        forSleepStartingAt start: Date,
        calendar: Calendar
    ) -> Date? {
        let hour = calendar.component(.hour, from: start)
        let midnight = calendar.startOfDay(for: start)
        guard hour >= dayBoundaryHour else {
            return midnight
        }
        return calendar.date(byAdding: .day, value: 1, to: midnight)
    }

    /// Collapses overlapping stretches into the time actually spent asleep.
    ///
    /// Health readily returns overlapping sleep samples: a watch and a phone
    /// and a third-party app all describe the same night, and adding their
    /// durations together reports eleven hours of sleep for a seven-hour
    /// night. Merging first is the difference between a figure someone can
    /// trust and one that flatters them.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else {
            return []
        }

        var merged: [DateInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                // Touching or overlapping: extend rather than append. `max` is
                // needed because a short stretch can sit wholly inside a long
                // one, and taking the later end unconditionally would shrink
                // the union.
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    /// Hours asleep per day, with overlaps counted once and each stretch filed
    /// under the night it belongs to.
    ///
    /// Merging happens across the whole set before anything is filed under a
    /// day, not within each day afterwards. Two records of the same night that
    /// happen to fall either side of the six o'clock boundary would otherwise
    /// land in different groups and never be compared, and the overlap they
    /// share would be counted twice — which is the exact failure merging is
    /// here to prevent.
    static func readings(
        from intervals: [DateInterval],
        calendar: Calendar
    ) -> [MetricReading] {
        var byDay: [Date: Double] = [:]
        for stretch in merge(intervals) {
            guard let day = day(forSleepStartingAt: stretch.start, calendar: calendar) else {
                continue
            }
            byDay[day, default: 0] += stretch.duration
        }

        return byDay
            .compactMap { day, seconds -> MetricReading? in
                guard seconds > 0 else {
                    return nil
                }
                return MetricReading(
                    start: day,
                    value: seconds / 3_600,
                    unit: "hr"
                )
            }
            .sorted { $0.start < $1.start }
    }
}
