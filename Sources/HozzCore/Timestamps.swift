import Foundation

/// The one place a date becomes text and text becomes a date.
///
/// In HozzCore because both sides of the wire need it: the phone writes these
/// strings and the receiver reads them, and a producer and parser that each
/// know the format separately is how two surfaces start disagreeing about what
/// a timestamp means.
public enum Timestamps {
    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let whole = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    public static func date(from text: String) -> Date? {
        // Both are tried because Hozz writes fractional seconds but other
        // producers pointed at the same receiver frequently do not.
        if let parsed = try? fractional.parse(text) {
            return parsed
        }
        return try? whole.parse(text)
    }

    public static func text(from date: Date) -> String {
        fractional.format(date)
    }
}
