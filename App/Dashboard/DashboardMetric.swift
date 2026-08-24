import Foundation
import HealthKit
import HozzHealth
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
            note: "Sleep is filed under the day you woke up. "
                + "Overlapping records are counted once."
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
    /// The day a stretch of sleep counts towards: the local day it ended on.
    ///
    /// If you fall asleep on Tuesday night and wake on Wednesday morning,
    /// everyone calls that Wednesday's sleep — you wake and say you slept seven
    /// hours last night. The rule needs no constant and no explaining.
    ///
    /// It replaced a rule that decided on the *start*, filing sleep begun at or
    /// after six in the evening under the following day. That grouped a night
    /// correctly and was wrong in three enumerable ways: a seven o'clock nap on
    /// Tuesday was filed under Wednesday, a day the sleeper was never asleep;
    /// someone asleep by 17:30 had the whole night filed under the day it
    /// began; and sleep crossing two midnights — 23:00 to 10:00 two days later
    /// — was filed a day before they woke. Deciding on the end is right in all
    /// three.
    ///
    /// It loses one case. Dozing 22:00–23:00 and then sleeping 23:30–07:00 is
    /// two stretches, and the doze is now filed under the evening it happened
    /// rather than joined to the night. That is defensible rather than plainly
    /// wrong, and it is the rarest of the four.
    ///
    /// This is also the rule `ExportMarkdownWriter` already ships, so the chart
    /// and the exported note now file the same night under the same day and say
    /// the same sentence about it. Two surfaces disagreeing about what "last
    /// night" means is how this was noticed.
    static func day(
        forSleepEndingAt end: Date,
        calendar: Calendar
    ) -> Date {
        calendar.startOfDay(for: end)
    }

    /// Collapses overlapping stretches into the time actually spent asleep.
    ///
    /// The implementation lives in `SleepIntervals`, shared with the exported
    /// note, because the two surfaces disagreeing about how long a night was
    /// is exactly what a second copy of this produced.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        SleepIntervals.merge(intervals)
    }

    /// Hours asleep per day, with overlaps counted once and each stretch filed
    /// under the day it ended on.
    ///
    /// Merging happens across the whole set before anything is filed under a
    /// day, not within each day afterwards. Two records of one night that fall
    /// either side of midnight would otherwise land in different groups and
    /// never be compared, and the overlap they share would be counted twice —
    /// the exact failure merging is here to prevent.
    static func readings(
        from intervals: [DateInterval],
        calendar: Calendar
    ) -> [MetricReading] {
        var byDay: [Date: Double] = [:]
        for stretch in merge(intervals) {
            let day = day(forSleepEndingAt: stretch.end, calendar: calendar)
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
