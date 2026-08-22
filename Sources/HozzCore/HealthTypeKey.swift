import Foundation

public struct HealthTypeKey: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "A health type key cannot be empty.")
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
