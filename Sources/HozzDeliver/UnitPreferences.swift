import Foundation

/// Which units a destination should receive.
///
/// Grouped by what a person actually has an opinion about rather than by
/// HealthKit's dimensions, which is why distance and body length are separate:
/// somebody who wants their runs in miles does not want their height in miles.
///
/// Every group defaults to leaving values exactly as Health gave them. That is
/// the setting an existing destination keeps across an update, and it is the
/// one that cannot be wrong.
public enum UnitFamily: String, CaseIterable, Sendable {
    case distance
    case bodyLength
    case mass
    case energy
    case temperature
    case speed
    case volume
    case bloodPressure

    public var displayName: String {
        switch self {
        case .distance:
            "Distance"
        case .bodyLength:
            "Height and body measurements"
        case .mass:
            "Weight"
        case .energy:
            "Energy"
        case .temperature:
            "Temperature"
        case .speed:
            "Speed"
        case .volume:
            "Volume"
        case .bloodPressure:
            "Blood pressure"
        }
    }

    /// The units offered for this group, in HealthKit's own spelling.
    public var choices: [String] {
        switch self {
        case .distance:
            ["km", "mi", "m"]
        case .bodyLength:
            ["cm", "in", "ft"]
        case .mass:
            ["kg", "lb", "st"]
        case .energy:
            ["kcal", "kJ"]
        case .temperature:
            ["degC", "degF"]
        case .speed:
            ["km/hr", "mi/hr", "m/s"]
        case .volume:
            ["L", "mL", "fl_oz_us"]
        case .bloodPressure:
            ["mmHg", "kPa"]
        }
    }

    /// What this group is called where the reader lives.
    ///
    /// The unit itself is never renamed — the payload carries HealthKit's
    /// spelling, so a receiver can look it up — but a picker offering
    /// `fl_oz_us` to choose between is a picker nobody can read.
    public static func displayName(forUnit unit: String) -> String {
        switch unit {
        case "km": "Kilometres"
        case "mi": "Miles"
        case "m": "Metres"
        case "cm": "Centimetres"
        case "in": "Inches"
        case "ft": "Feet"
        case "kg": "Kilograms"
        case "lb": "Pounds"
        case "st": "Stone"
        case "kcal": "Calories (kcal)"
        case "kJ": "Kilojoules"
        case "degC": "Celsius"
        case "degF": "Fahrenheit"
        case "km/hr": "Kilometres per hour"
        case "mi/hr": "Miles per hour"
        case "m/s": "Metres per second"
        case "L": "Litres"
        case "mL": "Millilitres"
        case "fl_oz_us": "US fluid ounces"
        case "mmHg": "mmHg"
        case "kPa": "Kilopascals"
        default: unit
        }
    }

    /// Which group a reading belongs to.
    ///
    /// The unit decides the dimension, because the unit is what the arithmetic
    /// needs and is always present. The type identifier only ever chooses
    /// between two groups that share a dimension, which is length: a distance
    /// and a waist measurement are both metres and want opposite answers.
    public static func of(unit: String, typeIdentifier: String) -> UnitFamily? {
        switch HealthUnit.dimension(of: unit) {
        case .length:
            return typeIdentifier.contains("Distance") ? .distance : .bodyLength
        case .mass:
            return .mass
        case .energy:
            return .energy
        case .temperature:
            return .temperature
        case .speed:
            return .speed
        case .volume:
            return .volume
        case .pressure:
            return .bloodPressure
        case .time, .none:
            // Seconds and minutes mean the same thing everywhere, and a count
            // or a percentage has nothing to convert into.
            return nil
        }
    }

    /// The key this group's choice is stored under.
    public var settingKey: String {
        "unit.\(rawValue)"
    }
}

/// One destination's unit choices, resolved.
public struct UnitPreferences: Equatable, Sendable {
    /// The unit each group should arrive in. A group that is absent is left
    /// exactly as Health gave it.
    public let units: [UnitFamily: String]

    public init(units: [UnitFamily: String] = [:]) {
        self.units = units
    }

    public static let asHealthProvides = UnitPreferences()

    public var isEmpty: Bool {
        units.isEmpty
    }

    /// What this reading should be converted to, if anything.
    ///
    /// Nil covers three different situations that all have the same right
    /// answer — no preference for this group, no group for this unit, and a
    /// preference that already matches — because in every one of them the
    /// correct thing to send is exactly what Health gave.
    public func target(for unit: String, typeIdentifier: String) -> String? {
        guard
            let family = UnitFamily.of(unit: unit, typeIdentifier: typeIdentifier),
            let target = units[family],
            target != unit,
            HealthUnit.canConvert(from: unit, to: target)
        else {
            return nil
        }
        return target
    }

    /// The choices a region implies, for the "use my region's units" switch.
    ///
    /// Resolved when the switch is turned on rather than read at delivery time,
    /// so a payload's units never change because somebody's phone changed
    /// region between one batch and the next.
    public static func forRegion(_ locale: Locale = .current) -> UnitPreferences {
        switch locale.measurementSystem {
        case .us:
            UnitPreferences(units: [
                .distance: "mi",
                .bodyLength: "in",
                .mass: "lb",
                .energy: "kcal",
                .temperature: "degF",
                .speed: "mi/hr",
                .volume: "fl_oz_us",
                .bloodPressure: "mmHg"
            ])
        case .uk:
            // Britain measures distance in miles and speed in miles per hour,
            // and everything else in metric. Sending it all imperial would be
            // as wrong as sending it all metric.
            UnitPreferences(units: [
                .distance: "mi",
                .bodyLength: "cm",
                .mass: "kg",
                .energy: "kcal",
                .temperature: "degC",
                .speed: "mi/hr",
                .volume: "mL",
                .bloodPressure: "mmHg"
            ])
        default:
            UnitPreferences(units: [
                .distance: "km",
                .bodyLength: "cm",
                .mass: "kg",
                .energy: "kcal",
                .temperature: "degC",
                .speed: "km/hr",
                .volume: "mL",
                .bloodPressure: "mmHg"
            ])
        }
    }
}

extension Destination {
    /// The unit choices stored on this destination.
    ///
    /// A stored unit this build does not recognise is ignored rather than
    /// treated as unsupported, and the reading goes out in the unit Health gave
    /// it. That is safe in a way an unrecognised *format* is not: every value
    /// Hozz emits carries its own unit, so a value that was not converted is
    /// still labelled correctly and can never be read as the unit somebody
    /// asked for. Nothing is ever mislabelled; at worst a preference does not
    /// take effect, and the payload says so on its face.
    public var unitPreferences: UnitPreferences {
        var units: [UnitFamily: String] = [:]
        for family in UnitFamily.allCases {
            guard
                let stored = options[family.settingKey],
                family.choices.contains(stored)
            else {
                continue
            }
            units[family] = stored
        }
        return UnitPreferences(units: units)
    }
}
