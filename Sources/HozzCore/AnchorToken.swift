import Foundation

public struct AnchorToken: Codable, Hashable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}
