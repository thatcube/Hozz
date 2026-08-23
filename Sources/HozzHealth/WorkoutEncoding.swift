import Foundation
import HozzCore

/// One of Health's own aggregates for a workout: the average heart rate over a
/// run, the total energy burned, and so on.
///
/// These are **summaries of samples that are exported separately**, not copies
/// of them. Each reading exists exactly once in an export, as itself; nothing
/// here repeats one, so no reading can be counted twice by reading both.
public struct WorkoutStatistic: Equatable, Sendable, Comparable {
    public let type: String
    public let unit: String
    /// Only the aggregates Health actually offers for this type are present.
    /// A discrete type like heart rate has an average, minimum, and maximum
    /// but no sum; a cumulative one like energy has a sum and none of the
    /// others. An absent aggregate is left out rather than written as zero.
    public let sum: Double?
    public let average: Double?
    public let minimum: Double?
    public let maximum: Double?

    public init(
        type: String,
        unit: String,
        sum: Double?,
        average: Double?,
        minimum: Double?,
        maximum: Double?
    ) {
        self.type = type
        self.unit = unit
        self.sum = sum
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.type < rhs.type
    }

    var object: [String: Any] {
        var object: [String: Any] = ["type": type, "unit": unit]
        if let sum {
            object["sum"] = sum
        }
        if let average {
            object["average"] = average
        }
        if let minimum {
            object["minimum"] = minimum
        }
        if let maximum {
            object["maximum"] = maximum
        }
        return object
    }
}

/// One leg of a workout: a swim, then a ride, then a run.
public struct WorkoutSegment: Equatable, Sendable {
    public let id: UUID
    public let activityType: UInt
    public let startDate: Date
    /// Absent while an activity is still running, which is a real state
    /// rather than a missing value.
    public let endDate: Date?
    public let statistics: [WorkoutStatistic]

    public init(
        id: UUID,
        activityType: UInt,
        startDate: Date,
        endDate: Date?,
        statistics: [WorkoutStatistic]
    ) {
        self.id = id
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.statistics = statistics
    }

    var object: [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString.lowercased(),
            "activityType": activityType,
            "startDate": WorkoutEncoding.timestamp(startDate),
            "statistics": statistics.sorted().map(\.object)
        ]
        if let endDate {
            object["endDate"] = WorkoutEncoding.timestamp(endDate)
        }
        return object
    }
}

public enum WorkoutEncoding {
    /// Adds what makes a workout analysable rather than one summary row.
    ///
    /// Health computes these aggregates itself and carries them on the workout
    /// sample, so they cost no extra query. Before this, a workout exported as
    /// an activity type and a duration: you could tell that a run happened,
    /// but nothing about how it went.
    ///
    /// Sorted, because Health hands the statistics over in a dictionary and an
    /// export that reorders itself between runs is not deterministic.
    static func decorate(
        _ object: inout [String: Any],
        statistics: [WorkoutStatistic],
        segments: [WorkoutSegment]
    ) {
        object["statistics"] = statistics.sorted().map(\.object)
        if !segments.isEmpty {
            // A triathlon is one workout and three efforts, and an average
            // across all three describes none of them.
            object["activities"] = segments.map(\.object)
        }
    }

    static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
