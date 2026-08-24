import Foundation

/// The union of a set of time stretches, in seconds.
///
/// Sleep arrives as separate records, and two devices describing the same night
/// both write one — a watch and a phone, or a watch and a third-party sleep app.
/// Adding their durations counts that night twice, and the answer looks like an
/// unusually good night's sleep rather than like an error, which is the worst
/// way for a number to be wrong.
///
/// This lives here rather than in either surface because the phone's dashboard
/// and the Markdown export both need it, and two implementations of one rule is
/// how the day-boundary bug happened: they agreed until they did not, and
/// nothing said which was right.
public enum TimeUnion {
    /// Merges touching and overlapping stretches, keeping each moment once.
    ///
    /// Touching counts as overlapping. A record ending at 23:00 and another
    /// beginning at 23:00 describe one continuous stretch of sleep, not two
    /// abutting ones, and treating them separately would report a gap that the
    /// sleeper did not experience.
    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else {
            return []
        }

        var merged: [DateInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                // `max` is needed because a short stretch can sit wholly inside
                // a long one, and taking the later end unconditionally would
                // shrink the union rather than extend it.
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

    /// How long the union covers, in seconds.
    public static func seconds(of intervals: [DateInterval]) -> Double {
        merge(intervals).reduce(0) { $0 + $1.duration }
    }
}
