import Foundation

public struct CapturedHealthObject: Hashable, Sendable {
    public let id: UUID
    public let type: HealthTypeKey
    public let canonicalPayload: Data

    public init(id: UUID, type: HealthTypeKey, canonicalPayload: Data) {
        self.id = id
        self.type = type
        self.canonicalPayload = canonicalPayload
    }
}

public struct CapturedHealthDeletion: Hashable, Sendable {
    public let id: UUID
    public let type: HealthTypeKey

    public init(id: UUID, type: HealthTypeKey) {
        self.id = id
        self.type = type
    }
}

public enum HealthChange: Hashable, Sendable {
    case upsert(CapturedHealthObject)
    case delete(CapturedHealthDeletion)

    public var type: HealthTypeKey {
        switch self {
        case .upsert(let object):
            object.type
        case .delete(let deletion):
            deletion.type
        }
    }

    /// Roughly what this change costs to hold, in bytes.
    ///
    /// Used to bound a batch by size rather than only by count. Most records
    /// are a single sample of a few hundred bytes, but a series record carries
    /// five hundred GPS points or voltage readings and is tens of kilobytes,
    /// so counting alone stopped being a bound on memory.
    public var approximateByteCount: Int {
        switch self {
        case .upsert(let object):
            object.canonicalPayload.count
        case .delete:
            // A tombstone is a short line with an identifier and a type.
            128
        }
    }
}
