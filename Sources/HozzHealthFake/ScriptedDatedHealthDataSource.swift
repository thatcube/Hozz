import Foundation
import HozzCore

public enum ScriptedDatedFault: Hashable, Sendable {
    /// The query throws, as a Health read does when the device is locked.
    case fail
    /// The query cancels the task that asked for it, which is what iOS taking
    /// its background time back looks like from inside a pass.
    case cancelTask
    /// The query claims the window overflowed however few samples are in it, so
    /// a test can drive the narrowing path without inventing dense fixtures.
    case truncate
}

/// One scripted sample, with the date a dated read would find it by.
public struct ScriptedDatedSample: Hashable, Sendable {
    public let change: HealthChange
    public let start: Date

    public init(change: HealthChange, start: Date) {
        self.change = change
        self.start = start
    }
}

/// A dated source over a scripted set of samples.
///
/// The window is applied exactly as ``DatedHealthDataSource`` describes it —
/// half-open, `[start, end)` — because a fake that was more forgiving than
/// HealthKit about boundaries would hide precisely the bug that matters, a
/// record falling between two abutting chunks.
public actor ScriptedDatedHealthDataSource: DatedHealthDataSource {
    private var samples: [HealthTypeKey: [ScriptedDatedSample]]
    private var faults: [HealthTypeKey: [Int: ScriptedDatedFault]]
    private var queries: [HealthTypeKey: Int] = [:]
    private var windows: [HealthTypeKey: [Range<Date>]] = [:]

    public init(
        samples: [HealthTypeKey: [ScriptedDatedSample]] = [:],
        faults: [HealthTypeKey: [Int: ScriptedDatedFault]] = [:]
    ) {
        self.samples = samples
        self.faults = faults
    }

    public func append(_ sample: ScriptedDatedSample, to type: HealthTypeKey) {
        samples[type, default: []].append(sample)
    }

    public func setFaults(_ faults: [Int: ScriptedDatedFault], for type: HealthTypeKey) {
        self.faults[type] = faults
    }

    public func queryCount(for type: HealthTypeKey) -> Int {
        queries[type, default: 0]
    }

    /// Every window this type was asked for, in the order it was asked.
    ///
    /// Lets a test assert that the walk really did go newest-first and really
    /// did abut, rather than trusting the engine's own account of itself.
    public func requestedWindows(for type: HealthTypeKey) -> [Range<Date>] {
        windows[type, default: []]
    }

    public func changes(
        for type: HealthTypeKey,
        from start: Date,
        to end: Date,
        limit: Int
    ) async throws -> DatedHealthChanges {
        queries[type, default: 0] += 1
        windows[type, default: []].append(start..<end)
        let queryNumber = queries[type, default: 0]

        switch faults[type]?[queryNumber] {
        case .fail:
            throw ScriptedHealthDataSourceError.injectedFailure
        case .cancelTask:
            withUnsafeCurrentTask { $0?.cancel() }
        case .truncate:
            return .truncated
        case nil:
            break
        }

        let matched = samples[type, default: []]
            .filter { $0.start >= start && $0.start < end }
            .sorted { $0.start > $1.start }
        guard matched.count <= limit else {
            return .truncated
        }
        return DatedHealthChanges(changes: matched.map(\.change))
    }
}
