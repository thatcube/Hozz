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
}
