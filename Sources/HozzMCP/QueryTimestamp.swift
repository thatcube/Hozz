import Foundation
import HozzCore
import HozzReceive

/// Timestamps as a *question*, which is not the same thing as a timestamp as
/// stored data.
///
/// ``Timestamps`` parses what Hozz writes, and it is strict on purpose: a
/// stored record's date has one correct form. An argument arriving from an
/// assistant is different. A model asked "how many steps last week" will very
/// reasonably send `2026-08-17`, and until this existed that string parsed to
/// nothing, the filter was silently dropped, and the tool returned four years
/// of history — which the assistant then reported as last week.
///
/// So the two halves of the fix are here together: understand the forms people
/// actually send, and refuse the ones nobody could mean, saying which. Silently
/// discarding a filter is worse than either, because the answer looks fine.
enum QueryTimestamp {
    /// Where a bare date sits in a range.
    enum Edge {
        /// `2026-08-17` as a lower bound means that day from its first instant.
        case start
        /// As an upper bound it means that day *through* its last instant, both
        /// because the tool documents its range as inclusive and because
        /// nobody saying "to the 17th" means "up to midnight on the 17th".
        case end
    }

    static func parse(
        _ text: String,
        as edge: Edge,
        argument: String,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // A full timestamp is unambiguous and is taken exactly as given.
        if let exact = Timestamps.date(from: trimmed) {
            return exact
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        if let day = bareDate(trimmed, calendar: calendar) {
            switch edge {
            case .start:
                return day
            case .end:
                // The last instant of that local day. Adding a day and stepping
                // back keeps it right on the two days a year that are 23 or 25
                // hours long.
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                    return day
                }
                return next.addingTimeInterval(-0.001)
            }
        }

        // A local wall clock with no zone: `2026-08-17T09:30:00`. Read in the
        // same zone the buckets are built in, which is the one the person
        // asking is standing in.
        if let local = localTimestamp(trimmed, calendar: calendar) {
            return local
        }

        throw MCPError.unreadableArgument(
            name: argument,
            value: text,
            expected: "a date like 2026-08-17, or a timestamp like "
                + "2026-08-17T09:30:00Z"
        )
    }

    private static func bareDate(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            return nil
        }
        // `Calendar` will happily roll 31 February into March. A date nobody
        // could have meant is a mistake worth naming, not one to reinterpret.
        guard calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func localTimestamp(_ text: String, calendar: Calendar) -> Date? {
        let separators = CharacterSet(charactersIn: "T ")
        let halves = text.components(separatedBy: separators as CharacterSet)
            .filter { !$0.isEmpty }
        guard halves.count == 2,
              let day = bareDate(halves[0], calendar: calendar) else {
            return nil
        }
        let clock = halves[1].split(separator: ":")
        guard (2...3).contains(clock.count),
              let hour = Int(clock[0]),
              let minute = Int(clock[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        // Validated, not salvaged. `Int(prefix(while: isNumber)) ?? 0` read
        // `09:30:abc` as half past nine and `09:30:3600` as half past ten —
        // discarding or reinterpreting a component nobody could have meant,
        // which is the exact failure this file exists to prevent.
        var second = 0
        if clock.count == 3 {
            guard let parsed = Int(clock[2]), (0...59).contains(parsed) else {
                return nil
            }
            second = parsed
        }
        return calendar.date(
            byAdding: DateComponents(hour: hour, minute: minute, second: second),
            to: day
        )
    }
}
