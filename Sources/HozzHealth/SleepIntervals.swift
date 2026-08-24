import Foundation
import HealthKit

/// The facts about sleep that both the chart and the exported note depend on,
/// kept in one place because they had drifted into two.
///
/// The chart and the note disagreed twice. They filed a night under different
/// days, and they disagreed about how long it lasted — the note added every
/// record it saw, so a night described by both a watch and a phone was counted
/// twice, and the note was the surface that flattered. Both were fixed by
/// picking one behaviour rather than correcting one copy, because a second copy
/// is what allowed them to differ in the first place.
///
/// Stage numbers live here too. They were written out as `1, 3, 4, 5` in one
/// place and as `HKCategoryValueSleepAnalysis` cases in another, which agreed
/// only until somebody edited one of them.
public enum SleepIntervals {
    /// Whether a sleep-analysis value means the person was asleep.
    ///
    /// `asleepUnspecified` is the old undifferentiated value; core, deep and
    /// REM are the stages that replaced it. In bed is not asleep and awake is
    /// not asleep — counting either is the commonest way a sleep figure
    /// flatters someone.
    public static func isAsleep(_ rawValue: Int) -> Bool {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
            true
        default:
            false
        }
    }

    /// Whether a sleep-analysis value means the person was in bed.
    ///
    /// Time in bed is a different measurement from time asleep, not a rounder
    /// version of it, and the two are reported separately.
    public static func isInBed(_ rawValue: Int) -> Bool {
        HKCategoryValueSleepAnalysis(rawValue: rawValue) == .inBed
    }

    /// Collapses overlapping and touching stretches into the time actually
    /// spent asleep.
    ///
    /// Health readily returns overlapping sleep samples: a watch, a phone and a
    /// third-party app all describe the same night, and adding their durations
    /// together reports eleven hours of sleep for a seven-hour night. Merging
    /// is the difference between a figure someone can trust and one that
    /// flatters them — and a total that is too high looks exactly like a total
    /// that is right, which is why it has to be prevented rather than spotted.
    ///
    /// Merging must happen across the whole set before anything is filed under
    /// a day. Two records of one night that end either side of midnight are
    /// filed under different days, so merging within each day afterwards would
    /// never compare them and would count their shared hours twice.
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

    /// Seconds of sleep per local day, with overlaps counted once and each
    /// stretch filed under the day it ended on — the day the sleeper woke up.
    ///
    /// This is the whole rule in one place, so the chart and the note cannot
    /// answer "how much did I sleep on Tuesday" differently.
    public static func secondsByDay(
        _ intervals: [DateInterval],
        dayNumber: (Date) -> Int
    ) -> [Int: Double] {
        var byDay: [Int: Double] = [:]
        for stretch in merge(intervals) {
            byDay[dayNumber(stretch.end), default: 0] += stretch.duration
        }
        return byDay
    }
}
