import Foundation

/// What a dated read of Health returned.
///
/// `isTruncated` is the whole reason this is not just an array. A dated query
/// is given a hard ceiling so one call cannot exhaust the memory a background
/// launch is allowed, and hitting that ceiling means the window holds *more
/// than* what came back — but not which more. A caller that treated a truncated
/// page as the window's contents would advance past records it never saw, which
/// is the one failure this app does not tolerate. So the changes in a truncated
/// batch are not a partial answer to be used; they are nothing, and the caller
/// is expected to ask again for a smaller window.
public struct DatedHealthChanges: Sendable, Equatable {
    public let changes: [HealthChange]
    /// True when the window holds more than the caller's ceiling allowed.
    ///
    /// `changes` is empty in that case: reading half a window is worse than
    /// reading none of it, because only one of those two is obviously unfinished.
    public let isTruncated: Bool

    public init(changes: [HealthChange], isTruncated: Bool = false) {
        self.changes = isTruncated ? [] : changes
        self.isTruncated = isTruncated
    }

    public static let truncated = DatedHealthChanges(changes: [], isTruncated: true)
}

/// Reads Health by date rather than by anchor.
///
/// The anchored sweep is the app's spine and stays that way: it is the only
/// reader that can see deletions, and the only one that can promise it has seen
/// everything, because Health hands it every change exactly once in the order
/// it was stored. The price of that promise is that the order is Health's, not
/// time's, so a sweep of a large type walks through years of history in an
/// arbitrary order and takes as long as it takes.
///
/// This reads the other way. It cannot promise completeness for a type and it
/// cannot see a deletion, so it can never replace the sweep. What it can do is
/// answer "what happened in these dates", which is what somebody looking at a
/// dashboard is actually asking, and it can answer it now.
///
/// Two things follow, and both are structural rather than advisory:
///
///   - No anchor appears anywhere in this protocol. There is no way for an
///     implementation of it to advance one, so a dated read cannot cause the
///     sweep to skip a record. That is the property the whole feature rests on,
///     and it is enforced by the shape of the type rather than by care.
///   - The window is half-open, `[start, end)`. Callers tile a range with
///     abutting windows, so a boundary sample must belong to exactly one of
///     them. An implementation that includes both endpoints is *safe* — the
///     receiver is idempotent, so the repeat costs bytes and nothing else — but
///     one that includes neither would drop a record on every boundary.
public protocol DatedHealthDataSource: Sendable {
    /// Reads every sample of `type` that starts in `[start, end)`, newest first.
    ///
    /// - Parameter limit: The most changes worth returning. Above it the reply
    ///   is ``DatedHealthChanges/truncated`` and carries nothing.
    func changes(
        for type: HealthTypeKey,
        from start: Date,
        to end: Date,
        limit: Int
    ) async throws -> DatedHealthChanges
}
