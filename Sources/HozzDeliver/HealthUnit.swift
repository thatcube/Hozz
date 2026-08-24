import Foundation

/// Converting a measurement from one unit to another, exactly.
///
/// Every factor here is a defined value rather than a rounded one — an inch is
/// exactly 0.0254 metres by international agreement, a pound is exactly
/// 0.45359237 kilograms, a thermochemical kilocalorie is exactly 4184 joules —
/// so a conversion introduces no error beyond what binary floating point costs
/// on any arithmetic at all. There is no place in this file for a number
/// somebody typed from memory.
///
/// Unit strings are HealthKit's own, because that is what the canonical record
/// carries and what a receiver can look up. Hozz does not invent a nicer name
/// for a unit; a unit renamed is a unit nobody can map back.
public enum HealthUnit {
    /// What kind of quantity a unit measures.
    ///
    /// Conversion is only ever attempted inside one of these. A length can
    /// never become a mass, and a unit this build does not recognise converts
    /// to nothing at all rather than to something plausible.
    public enum Dimension: String, Sendable, CaseIterable {
        case length
        case mass
        case energy
        case temperature
        case speed
        case volume
        case pressure
        case time
    }

    /// Units expressed as a multiple of their dimension's base unit.
    ///
    /// Base units: metre, gram, joule, metre per second, litre, pascal, second.
    /// Temperature is deliberately absent — it is not a scale, and treating it
    /// as one turns 20°C into 68°C rather than 68°F.
    private static let factors: [String: (Dimension, Double)] = [
        // Length, base metre. The imperial values are exact by definition:
        // the international yard is 0.9144 m, from which foot and inch follow.
        "m": (.length, 1),
        "cm": (.length, 0.01),
        "mm": (.length, 0.001),
        "km": (.length, 1_000),
        "in": (.length, 0.0254),
        "ft": (.length, 0.3048),
        "yd": (.length, 0.9144),
        "mi": (.length, 1_609.344),

        // Mass, base gram. A pound is exactly 0.45359237 kg; an ounce is a
        // sixteenth of that; a stone is fourteen pounds.
        "g": (.mass, 1),
        "kg": (.mass, 1_000),
        "mg": (.mass, 0.001),
        "mcg": (.mass, 0.000_001),
        "lb": (.mass, 453.59237),
        "oz": (.mass, 28.349_523_125),
        "st": (.mass, 6_350.293_18),

        // Energy, base joule. HealthKit's kilocalorie is the thermochemical
        // one, which is exactly 4184 J — not the 4186 of the fifteen-degree
        // calorie, and the difference is half a percent on a day's intake.
        // `Cal` with a capital C is HealthKit's large calorie and is the same
        // 4184 J; `cal` is the small calorie and is a thousandth of it. Getting
        // those two the same way round matters by a factor of a thousand.
        "J": (.energy, 1),
        "kJ": (.energy, 1_000),
        "cal": (.energy, 4.184),
        "Cal": (.energy, 4_184),
        "kcal": (.energy, 4_184),

        // Speed, base metre per second. A mile per hour is exactly 0.44704 m/s,
        // which follows from the exact mile.
        "m/s": (.speed, 1),
        "km/hr": (.speed, 1.0 / 3.6),
        "mi/hr": (.speed, 0.44704),

        // Volume, base litre. A US fluid ounce is a 128th of a US gallon, and
        // that gallon is exactly 3.785411784 L.
        "L": (.volume, 1),
        "mL": (.volume, 0.001),
        "fl_oz_us": (.volume, 3.785_411_784 / 128),
        "cup_us": (.volume, 3.785_411_784 / 16),
        "pt_us": (.volume, 3.785_411_784 / 8),

        // Pressure, base pascal. A millimetre of mercury is exactly
        // 133.322387415 Pa by definition.
        "Pa": (.pressure, 1),
        "kPa": (.pressure, 1_000),
        "hPa": (.pressure, 100),
        "mmHg": (.pressure, 133.322_387_415),
        "inHg": (.pressure, 25.4 * 133.322_387_415),
        "cmAq": (.pressure, 98.0665),
        "atm": (.pressure, 101_325),

        // Time, base second.
        "s": (.time, 1),
        "ms": (.time, 0.001),
        "min": (.time, 60),
        "hr": (.time, 3_600),
        "d": (.time, 86_400)
    ]

    private static let temperatures: Set<String> = ["degC", "degF", "K"]

    /// What this unit measures, or nil when Hozz has no arithmetic for it.
    ///
    /// A count, a percentage, a heart rate in `count/min` — anything with no
    /// entry here is left exactly as Health gave it. That is the right answer
    /// rather than a gap: there is nothing to convert a count into.
    public static func dimension(of unit: String) -> Dimension? {
        if temperatures.contains(unit) {
            return .temperature
        }
        return factors[unit]?.0
    }

    /// Whether a value in one unit can be expressed in the other.
    public static func canConvert(from source: String, to target: String) -> Bool {
        guard let from = dimension(of: source), let to = dimension(of: target) else {
            return false
        }
        return from == to
    }

    /// The value, expressed in the target unit, or nil when it cannot be.
    ///
    /// Returning nil rather than the original number is deliberate. A caller
    /// that got a number back would have no way to tell a converted value from
    /// an unconverted one, and would go on to label kilograms as pounds.
    public static func convert(
        _ value: Double,
        from source: String,
        to target: String
    ) -> Double? {
        guard value.isFinite else {
            // A NaN or an infinity is not a measurement. Passing it through the
            // arithmetic would produce another one and hide where it came from.
            return nil
        }
        if source == target {
            return value
        }
        guard canConvert(from: source, to: target) else {
            return nil
        }
        if dimension(of: source) == .temperature {
            return convertTemperature(value, from: source, to: target)
        }
        guard let from = factors[source], let to = factors[target] else {
            return nil
        }
        return value * from.1 / to.1
    }

    /// Temperature is an interval scale with an offset, not a ratio scale.
    ///
    /// Multiplying by a factor is right for every other dimension here and
    /// wrong for this one: it would make 0°C convert to 0°F, and a fever of
    /// 38°C read as 38°F, which is hypothermia.
    private static func convertTemperature(
        _ value: Double,
        from source: String,
        to target: String
    ) -> Double? {
        let celsius: Double
        switch source {
        case "degC":
            celsius = value
        case "degF":
            celsius = (value - 32) * 5 / 9
        case "K":
            celsius = value - 273.15
        default:
            return nil
        }

        switch target {
        case "degC":
            return celsius
        case "degF":
            return celsius * 9 / 5 + 32
        case "K":
            return celsius + 273.15
        default:
            return nil
        }
    }
}
