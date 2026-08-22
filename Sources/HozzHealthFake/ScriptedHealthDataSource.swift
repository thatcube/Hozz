import Foundation
import HozzCore

public enum ScriptedHealthDataSourceError: Error, Equatable, Sendable {
    case invalidLimit
    case malformedAnchor
    case anchorBeyondStream
    case injectedFailure
}

public enum ScriptedQueryFault: Hashable, Sendable {
    case fail
    case holdAnchor
    case replaceFirstChangeType(HealthTypeKey)
}

public actor ScriptedHealthDataSource: HealthDataSource {
    private var streams: [HealthTypeKey: [HealthChange]]
    private var queries: [HealthTypeKey: Int] = [:]
    private var faults: [HealthTypeKey: [Int: ScriptedQueryFault]]

    public init(
        streams: [HealthTypeKey: [HealthChange]] = [:],
        faults: [HealthTypeKey: [Int: ScriptedQueryFault]] = [:]
    ) {
        self.streams = streams
        self.faults = faults
    }

    public func append(_ change: HealthChange, to type: HealthTypeKey) throws {
        guard change.type == type else {
            throw DrainFixtureError.unexpectedType(expected: type, actual: change.type)
        }
        streams[type, default: []].append(change)
    }

    public func queryCount(for type: HealthTypeKey) -> Int {
        queries[type, default: 0]
    }

    public func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        guard limit > 0 else {
            throw ScriptedHealthDataSourceError.invalidLimit
        }

        let offset = try Self.decode(anchor)
        let stream = streams[type, default: []]
        guard offset <= stream.count else {
            throw ScriptedHealthDataSourceError.anchorBeyondStream
        }

        queries[type, default: 0] += 1
        let queryNumber = queries[type, default: 0]
        let end = min(offset + limit, stream.count)
        var batch = Array(stream[offset..<end])
        var proposedAnchor = Self.anchor(for: end)

        if let fault = faults[type]?[queryNumber] {
            switch fault {
            case .fail:
                throw ScriptedHealthDataSourceError.injectedFailure
            case .holdAnchor:
                proposedAnchor = anchor ?? Self.anchor(for: 0)
            case .replaceFirstChangeType(let replacement):
                if let first = batch.first {
                    batch[0] = first.replacingType(with: replacement)
                }
            }
        }

        return HealthChangeBatch(
            changes: batch,
            proposedAnchor: proposedAnchor
        )
    }

    private static func anchor(for offset: Int) -> AnchorToken {
        var value = UInt64(offset).bigEndian
        return withUnsafeBytes(of: &value) { bytes in
            AnchorToken(data: Data(bytes))
        }
    }

    private static func decode(_ anchor: AnchorToken?) throws -> Int {
        guard let anchor else {
            return 0
        }
        guard anchor.data.count == MemoryLayout<UInt64>.size else {
            throw ScriptedHealthDataSourceError.malformedAnchor
        }

        let offset = anchor.data.reduce(UInt64.zero) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        guard offset <= UInt64(Int.max) else {
            throw ScriptedHealthDataSourceError.malformedAnchor
        }
        return Int(offset)
    }
}

public enum DrainFixtureError: Error, Equatable, Sendable {
    case unexpectedType(expected: HealthTypeKey, actual: HealthTypeKey)
}

private extension HealthChange {
    func replacingType(with type: HealthTypeKey) -> HealthChange {
        switch self {
        case .upsert(let object):
            .upsert(
                CapturedHealthObject(
                    id: object.id,
                    type: type,
                    canonicalPayload: object.canonicalPayload
                )
            )
        case .delete(let deletion):
            .delete(CapturedHealthDeletion(id: deletion.id, type: type))
        }
    }
}
