import Foundation
public struct LocalDayExpression {
    private struct Segment { let until: Date; let offsetSeconds: Int }
    private let segments: [Segment]
    private let finalOffset: Int
    private static let bias = 62_135_596_800
    public init(timeZone: TimeZone, from start: Date, to end: Date) {
        var segments: [Segment] = []
        var cursor = start
        var offset = timeZone.secondsFromGMT(for: start)
        var guardCount = 0
        while let next = timeZone.nextDaylightSavingTimeTransition(after: cursor), next < end, guardCount < 512 {
            segments.append(Segment(until: next, offsetSeconds: offset))
            offset = timeZone.secondsFromGMT(for: next)
            cursor = next
            guardCount += 1
        }
        self.segments = segments
        self.finalOffset = offset
    }
    public func day(for date: Date, timeZone: TimeZone) -> Int {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        return (seconds + timeZone.secondsFromGMT(for: date) + Self.bias) / 86400
    }
}
