import Foundation

/// How a dated prime walks a window backwards, one chunk at a time.
///
/// This is arithmetic and nothing else: no Health, no store, no clock. It
/// exists as its own type because the decisions it makes are the ones that
/// decide whether a prime is lossless, and a decision buried inside an engine
/// is a decision nobody can test in isolation.
///
/// The shape of the walk:
///
///   - A prime owns a window `[windowStart, windowEnd)` and a `frontier`,
///     which means *everything from the frontier up to the window's end has
///     been delivered*. It starts at `windowEnd`, meaning nothing, and moves
///     down towards `windowStart`.
///   - Each step reads one chunk `[chunkStart, frontier)` and, only once the
///     destination has accepted it, moves the frontier down to `chunkStart`.
///     Chunks abut exactly, so the walk tiles the window with no seam a record
///     could fall through.
///   - Because the frontier moves only after delivery, a prime killed mid-chunk
///     resumes by re-reading that chunk. The receiver upserts on `(id, type)`,
///     so the repeat is bytes and nothing else — which is the trade this whole
///     design is built on: never skip, occasionally repeat.
///
/// The chunk *length* adapts, because density varies by four orders of
/// magnitude across Health types. A body mass reading arrives monthly; a heart
/// rate can arrive every few seconds. One fixed chunk would either take
/// thousands of queries to cross ninety days of body mass, or return far more
/// heart rate than a background launch can hold.
public enum PrimePlan {
    /// The default span a prime aims at: enough for a dashboard to say
    /// something true about the recent past, small enough to finish.
    ///
    /// Deliberately not a choice put to the user. Someone setting up a health
    /// exporter is not in a position to know how dense their own heart rate
    /// data is, and any answer they gave would be a guess that permanently
    /// shaped what they saw. The sweep continues to everything regardless, so
    /// this number decides how soon recent data appears and nothing else.
    public static let defaultSpan: TimeInterval = 90 * 86_400

    /// The most records one chunk may carry.
    ///
    /// A chunk is delivered whole or not at all, so this is also the largest
    /// bite a single prime step can take out of a pass's budget.
    public static let chunkCapacity = 500

    /// Where a type with no history of its own starts.
    ///
    /// Three days is a compromise nobody has to live with for long: the first
    /// two or three chunks of a type correct it towards that type's real
    /// density, and the corrected value is what gets stored.
    public static let initialChunk: TimeInterval = 3 * 86_400

    /// The shortest chunk worth asking for.
    ///
    /// Below this the query overhead dominates and the walk would take
    /// thousands of round trips to cross a day. A type dense enough to overflow
    /// a minute is reported as stalled rather than read incorrectly.
    public static let minimumChunk: TimeInterval = 60

    /// The longest chunk worth asking for, so an empty type crosses a decade in
    /// a handful of queries without ever asking Health for an unbounded range.
    public static let maximumChunk: TimeInterval = 400 * 86_400

    /// The share of a chunk's capacity the planner aims to fill.
    ///
    /// Aiming at the ceiling would overshoot it about half the time, and an
    /// overshoot costs a wasted query *and* a narrowing that then has to be
    /// undone. Aiming below it is cheaper than being right.
    public static let targetFill = 0.7

    /// The window a fresh prime aims at, ending now.
    public static func window(
        endingAt end: Date,
        span: TimeInterval = defaultSpan
    ) -> (start: Date, end: Date) {
        (end.addingTimeInterval(-max(span, 0)), end)
    }

    /// The next chunk to read, or nil when the frontier has reached the start.
    ///
    /// The chunk is clamped to the window, so the last one lands exactly on
    /// `windowStart` however awkward the chunk length is. That exactness is the
    /// point: a final chunk that overshot would leave the frontier below the
    /// window and a prime that claimed more than it read.
    public static func chunk(
        frontier: Date,
        windowStart: Date,
        seconds: TimeInterval
    ) -> Range<Date>? {
        guard frontier > windowStart else {
            return nil
        }
        let length = clamp(seconds)
        let proposed = frontier.addingTimeInterval(-length)
        let start = max(proposed, windowStart)
        return start..<frontier
    }

    /// A shorter chunk to try after one came back over capacity.
    ///
    /// Quartering rather than halving because the only thing a truncated read
    /// tells us is "more than the ceiling" — the density could be anything
    /// above it, and two wasted queries cost more than one chunk that turns out
    /// smaller than it needed to be.
    public static func narrowed(_ seconds: TimeInterval) -> TimeInterval {
        max(minimumChunk, clamp(seconds) / 4)
    }

    /// The chunk length to use next, given how full the last one turned out.
    ///
    /// A completed chunk is a measurement of density, not just a success, so
    /// the next length is computed from it rather than nudged. An empty chunk
    /// has no density to measure, so it grows by a fixed factor instead of
    /// dividing by zero.
    public static func resized(
        _ seconds: TimeInterval,
        after count: Int,
        capacity: Int = chunkCapacity
    ) -> TimeInterval {
        let current = clamp(seconds)
        guard capacity > 0 else {
            return current
        }
        guard count > 0 else {
            // Growth is capped even here. An empty stretch says nothing about
            // the stretch before it, and a type that is empty for a year but
            // dense before that would otherwise leap the whole way in one
            // chunk and immediately overflow it.
            return clamp(current * 8)
        }

        let target = Double(capacity) * targetFill
        let scale = min(8, max(0.25, target / Double(count)))
        return clamp(current * scale)
    }

    /// Whether a chunk is as short as the planner is willing to ask for.
    ///
    /// A chunk this short that *still* overflows cannot be narrowed further,
    /// and the honest response is to stop and say so rather than to deliver a
    /// truncated read as though it were the window's contents.
    public static func isAtMinimum(_ seconds: TimeInterval) -> Bool {
        clamp(seconds) <= minimumChunk
    }

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > minimumChunk else {
            return minimumChunk
        }
        return min(seconds, maximumChunk)
    }
}
