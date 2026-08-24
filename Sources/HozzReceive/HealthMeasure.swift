import Foundation

/// What a column of a chart means for one type.
///
/// The distinction is not cosmetic. Adding up 300 heart rate readings produces a
/// number with no meaning at all, and averaging a day's step samples reports a
/// person walked sixty-five steps. Health itself draws the same line — every
/// quantity type is either cumulative or discrete — so the classification is
/// stated explicitly here rather than inferred from a unit, because a wrong
/// guess in either direction produces a confident, wrong, believable number.
public enum MeasureKind: String, Sendable, Hashable {
    /// Values accumulate: a column is their total.
    case total
    /// Values are measurements: a column is their average.
    case average
    /// The sample's value is an enumeration, and what accumulates is the time it
    /// covers. Sleep stages and mindful minutes are both this.
    case duration
    /// The sample's value is an enumeration and only its occurrence counts.
    case occurrences

    public var noun: String {
        switch self {
        case .total: "Total"
        case .average: "Average"
        case .duration: "Time"
        case .occurrences: "Count"
        }
    }
}

/// A unit as a person should read it, and how to get there from what is stored.
///
/// Health stores in its own canonical units, which are frequently not the ones
/// anybody uses. A heart rate arrives as `count/s`, so a chart that draws the
/// stored number shows a resting pulse of 1.08. A percentage arrives as a
/// fraction, so blood oxygen reads 0.96%. Both render beautifully and both are
/// wrong, which is worse than not drawing them.
public struct DisplayUnit: Sendable, Hashable {
    public let label: String
    /// Stored value × `scale` = displayed value.
    public let scale: Double
    public let fractionDigits: Int

    public init(label: String, scale: Double = 1, fractionDigits: Int = 0) {
        self.label = label
        self.scale = scale
        self.fractionDigits = fractionDigits
    }

    public func convert(_ value: Double) -> Double {
        value * scale
    }

    public func format(_ value: Double) -> String {
        let converted = convert(value)
        return converted.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.automatic)
        )
    }

    /// The value and its unit, as one string.
    public func formatted(_ value: Double) -> String {
        label.isEmpty ? format(value) : "\(format(value)) \(label)"
    }
}

/// How one health type should be read, charted and described.
public struct HealthMeasure: Sendable, Hashable {
    public let type: String
    public let kind: MeasureKind
    /// The unit values are stored in, when the archive holds one.
    public let storedUnit: String?
    /// Category values that count towards a `duration` or `occurrences` measure.
    /// Empty means every sample counts.
    public let countedValues: Set<Int>

    public init(
        type: String,
        kind: MeasureKind,
        storedUnit: String?,
        countedValues: Set<Int> = []
    ) {
        self.type = type
        self.kind = kind
        self.storedUnit = storedUnit
        self.countedValues = countedValues
    }

    public var displayName: String {
        HealthMeasure.strippedName(type)
    }

    /// Whether a total of this type would be a meaningless number.
    ///
    /// Kept as a property rather than left implicit so a test can assert it
    /// directly: a measured type must never be summed anywhere in the app.
    public var isSummable: Bool {
        kind == .total || kind == .duration || kind == .occurrences
    }

    // MARK: - Display units

    /// The unit to draw a series in, given how large its values actually are.
    ///
    /// Chosen per series rather than fixed per type because the same type spans
    /// orders of magnitude depending on the column width: a day's cycling is 400
    /// metres and a month's is 68 kilometres, and neither reads well in the
    /// other's unit.
    public func displayUnit(forMagnitude magnitude: Double) -> DisplayUnit {
        let size = abs(magnitude)
        switch kind {
        case .duration:
            // Stored as seconds by the duration query, not as a sample value.
            return size >= 5400
                ? DisplayUnit(label: "hr", scale: 1.0 / 3600, fractionDigits: 1)
                : DisplayUnit(label: "min", scale: 1.0 / 60, fractionDigits: 0)
        case .occurrences:
            return DisplayUnit(label: "", scale: 1, fractionDigits: 0)
        case .total, .average:
            break
        }

        switch storedUnit {
        case "count/s":
            // Per-second rates are stored that way and read per minute by
            // everyone including Health's own summary line.
            return DisplayUnit(label: perMinuteLabel, scale: 60, fractionDigits: 0)
        case "%":
            // Health's percent unit is a fraction. 0.957 is 95.7%.
            return DisplayUnit(label: "%", scale: 100, fractionDigits: 1)
        case "m":
            if isDistance {
                return size >= 1000
                    ? DisplayUnit(label: "km", scale: 0.001, fractionDigits: 2)
                    : DisplayUnit(label: "m", scale: 1, fractionDigits: 0)
            }
            return DisplayUnit(label: "m", scale: 1, fractionDigits: 2)
        case "min":
            return size >= 90
                ? DisplayUnit(label: "hr", scale: 1.0 / 60, fractionDigits: 1)
                : DisplayUnit(label: "min", scale: 1, fractionDigits: 0)
        case "g":
            // Micronutrients are stored in grams and read in milligrams;
            // "0.0 g of vitamin D" is a true number that tells nobody anything.
            return size < 1
                ? DisplayUnit(label: "mg", scale: 1000, fractionDigits: 1)
                : DisplayUnit(label: "g", scale: 1, fractionDigits: 1)
        case "kcal":
            return DisplayUnit(label: "kcal", scale: 1, fractionDigits: 0)
        case "count/min":
            return DisplayUnit(label: perMinuteLabel, scale: 1, fractionDigits: 0)
        case "count":
            return DisplayUnit(
                label: "",
                scale: 1,
                fractionDigits: kind == .total ? 0 : 1
            )
        case "degC":
            return DisplayUnit(label: "°C", scale: 1, fractionDigits: 2)
        case "degF":
            return DisplayUnit(label: "°F", scale: 1, fractionDigits: 1)
        case "kg":
            return DisplayUnit(label: "kg", scale: 1, fractionDigits: 1)
        case "ms":
            return DisplayUnit(label: "ms", scale: 1, fractionDigits: 0)
        case "mL":
            return DisplayUnit(label: "mL", scale: 1, fractionDigits: 0)
        case .some(let unit):
            return DisplayUnit(label: unit, scale: 1, fractionDigits: 1)
        case nil:
            return DisplayUnit(label: "", scale: 1, fractionDigits: 1)
        }
    }

    private var perMinuteLabel: String {
        if type.hasSuffix("HeartRate")
            || type.hasSuffix("HeartRateAverage")
            || type.hasSuffix("RestingHeartRate") {
            return "bpm"
        }
        if type.hasSuffix("RespiratoryRate") {
            return "breaths/min"
        }
        return "count/min"
    }

    private var isDistance: Bool {
        type.contains("Distance") || type.hasSuffix("WalkTestDistance")
    }

    // MARK: - Classification

    /// Cumulative quantity type suffixes, as Health defines them.
    ///
    /// Everything absent from this list is treated as a measurement and is
    /// averaged, which is the safe direction to be wrong in: averaging something
    /// cumulative understates it visibly, while summing something measured
    /// produces a number nobody can sanity-check.
    ///
    /// Checked against `HKQuantityType.aggregationStyle` rather than reasoned
    /// about. Three plausible-looking entries came out after that check.
    /// `UVExposure` and `AppleSleepingBreathingDisturbances` are
    /// `discreteArithmetic` — an index and a per-night level, neither of which
    /// means anything added up. `EnvironmentalSoundReduction` is
    /// `discreteEquivalentContinuousLevel` in decibels, where a sum is not
    /// merely inaccurate but undefined, decibels being logarithmic; that one
    /// was the tell, because `EnvironmentalAudioExposure` has the identical
    /// style and unit and was already correctly absent. `HeartbeatSeries` went
    /// too, as inert: no quantity type identifier ends in it.
    private static let cumulativeSuffixes: Set<String> = [
        "StepCount",
        "PushCount",
        "SwimmingStrokeCount",
        "FlightsClimbed",
        "NikeFuel",
        "ActiveEnergyBurned",
        "BasalEnergyBurned",
        "AppleExerciseTime",
        "AppleMoveTime",
        "AppleStandTime",
        "TimeInDaylight",
        "InhalerUsage",
        "InsulinDelivery",
        "NumberOfTimesFallen",
        "NumberOfAlcoholicBeverages"
    ]

    /// Category types whose value is an enumeration and whose columns are time.
    private static let durationCategories: [String: Set<Int>] = [
        // HKCategoryValueSleepAnalysis: 0 inBed, 1 asleepUnspecified, 2 awake,
        // 3 asleepCore, 4 asleepDeep, 5 asleepREM. Time in bed is not time
        // asleep and awake is neither, so only the asleep values are counted.
        "HKCategoryTypeIdentifierSleepAnalysis": [1, 3, 4, 5],
        "HKCategoryTypeIdentifierMindfulSession": []
    ]

    /// Category types counted by occurrence, with the values that count.
    private static let occurrenceCategories: [String: Set<Int>] = [
        // HKCategoryValueAppleStandHour: 0 stood, 1 idle. Summing the raw value
        // totals the *idle* hours and labels them a total, which is how the
        // first version of this chart quietly inverted the ring.
        "HKCategoryTypeIdentifierAppleStandHour": [0]
    ]

    /// How to read a type, from its identifier and the unit it arrived in.
    ///
    /// Deliberately driven by the identifier's own prefix rather than by the
    /// generated type catalogue. The prefix carries the same fact — a
    /// `HKCategoryTypeIdentifier` is a category whatever else changes — and the
    /// unit the archive actually holds is a better answer than the unit the
    /// catalogue expects, because it is what the values in front of us are in.
    public static func measure(for type: String, storedUnit: String?) -> HealthMeasure {
        if let counted = durationCategories[type] {
            return HealthMeasure(
                type: type,
                kind: .duration,
                storedUnit: nil,
                countedValues: counted
            )
        }
        if let counted = occurrenceCategories[type] {
            return HealthMeasure(
                type: type,
                kind: .occurrences,
                storedUnit: nil,
                countedValues: counted
            )
        }

        if type.hasPrefix("HKCategoryTypeIdentifier") {
            // An unrecognised category carries an enumeration this build has
            // no table for. Counting how many arrived is true whatever the
            // values mean; charting the values themselves would not be.
            return HealthMeasure(type: type, kind: .occurrences, storedUnit: nil)
        }
        if !type.hasPrefix("HKQuantityTypeIdentifier") {
            // Workouts, routes, mood, medication, audiograms: none of them
            // carry a single number that means anything charted over time.
            // Each has a view of its own; here they are simply counted.
            return HealthMeasure(type: type, kind: .occurrences, storedUnit: nil)
        }

        let name = strippedIdentifier(type)
        let isCumulative = cumulativeSuffixes.contains(name)
            || name.hasPrefix("Dietary")
            || name.hasPrefix("Distance")
        return HealthMeasure(
            type: type,
            kind: isCumulative ? .total : .average,
            storedUnit: storedUnit
        )
    }

    private static let prefixes = [
        "HKQuantityTypeIdentifier",
        "HKCategoryTypeIdentifier",
        "HKCharacteristicTypeIdentifier",
        "HKCorrelationTypeIdentifier",
        "HKClinicalTypeIdentifier",
        "HKScoredAssessmentTypeIdentifier"
    ]

    static func strippedIdentifier(_ type: String) -> String {
        for prefix in prefixes where type.hasPrefix(prefix) {
            return String(type.dropFirst(prefix.count))
        }
        return type
    }

    static func strippedName(_ type: String) -> String {
        let name = strippedIdentifier(type)
        guard !name.isEmpty else {
            return type
        }
        return name.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
    }
}
