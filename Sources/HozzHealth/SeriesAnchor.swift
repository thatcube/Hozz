import Foundation
import HozzCore

public enum SeriesAnchorError: Error, LocalizedError, Equatable, Sendable {
    case malformed

    public var errorDescription: String? {
        switch self {
        case .malformed:
            "Hozz could not read a stored series cursor."
        }
    }
}

/// Where Hozz is inside a series type's stream.
///
/// A workout route or an electrocardiogram is one HealthKit sample whose real
/// content is a separate stream — hundreds of thousands of GPS points, or tens
/// of thousands of voltage readings. Draining one takes more than a single
/// page, so a cursor has to say more than "which sample came next": it has to
/// say which sample is half-read and how far in.
///
/// Without that, an export interrupted in the middle of a long ride would
/// either replay it, duplicating what was already written, or skip the rest
/// and lose it. Both are exactly what the anchor rule exists to prevent, so
/// the position inside a sample is part of the anchor.
public struct SeriesAnchor: Equatable, Sendable {
    /// HealthKit's own anchor, already positioned *after* ``pendingSample``.
    public let healthKitAnchor: Data?
    /// The sample whose elements are still being written, if any.
    public let pendingSample: UUID?
    /// How many of that sample's elements are already durable.
    public let deliveredElements: Int

    public init(
        healthKitAnchor: Data?,
        pendingSample: UUID? = nil,
        deliveredElements: Int = 0
    ) {
        self.healthKitAnchor = healthKitAnchor
        self.pendingSample = pendingSample
        self.deliveredElements = deliveredElements
    }

    public static let start = SeriesAnchor(healthKitAnchor: nil)

    public func token() throws -> AnchorToken {
        var object: [String: Any] = [
            "v": 1,
            "offset": deliveredElements
        ]
        if let healthKitAnchor {
            object["hk"] = healthKitAnchor.base64EncodedString()
        }
        if let pendingSample {
            object["sample"] = pendingSample.uuidString.lowercased()
        }
        return AnchorToken(
            data: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    public static func decode(_ token: AnchorToken?) throws -> SeriesAnchor {
        guard let token else {
            return .start
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: token.data)
                as? [String: Any],
            object["v"] as? Int == 1
        else {
            throw SeriesAnchorError.malformed
        }

        let healthKitAnchor: Data?
        if let encoded = object["hk"] as? String {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw SeriesAnchorError.malformed
            }
            healthKitAnchor = decoded
        } else {
            healthKitAnchor = nil
        }

        let sample = (object["sample"] as? String).flatMap(UUID.init(uuidString:))
        if object["sample"] != nil, sample == nil {
            throw SeriesAnchorError.malformed
        }

        let offset = object["offset"] as? Int ?? 0
        guard offset >= 0 else {
            throw SeriesAnchorError.malformed
        }
        // An offset with no sample would silently skip the start of whichever
        // sample came next, so it is rejected rather than assumed to be zero.
        guard sample != nil || offset == 0 else {
            throw SeriesAnchorError.malformed
        }

        return SeriesAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingSample: sample,
            deliveredElements: offset
        )
    }
}
