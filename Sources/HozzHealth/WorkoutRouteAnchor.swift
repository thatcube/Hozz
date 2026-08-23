import Foundation
import HozzCore

public enum WorkoutRouteAnchorError: Error, LocalizedError, Equatable, Sendable {
    case malformed

    public var errorDescription: String? {
        switch self {
        case .malformed:
            "Hozz could not read a stored workout route cursor."
        }
    }
}

/// Where Hozz is in the workout route stream.
///
/// A route is one HealthKit sample, but its locations are a separate stream
/// that can hold hundreds of thousands of points. Draining a route therefore
/// takes more than one page, and a cursor has to say more than "which sample
/// came next": it has to say which route is half-read and how far in.
///
/// Without that, an export interrupted in the middle of a long ride would
/// either replay the whole route (duplicating points already written) or skip
/// the rest of it (losing them). Both are exactly what the anchor rule exists
/// to prevent, so the position inside a route is part of the anchor.
public struct WorkoutRouteAnchor: Equatable, Sendable {
    /// HealthKit's own anchor, already positioned *after* ``pendingRoute``.
    public let healthKitAnchor: Data?
    /// The route whose locations are still being written, if any.
    public let pendingRoute: UUID?
    /// How many of that route's locations are already durable.
    public let deliveredLocations: Int

    public init(
        healthKitAnchor: Data?,
        pendingRoute: UUID? = nil,
        deliveredLocations: Int = 0
    ) {
        self.healthKitAnchor = healthKitAnchor
        self.pendingRoute = pendingRoute
        self.deliveredLocations = deliveredLocations
    }

    public static let start = WorkoutRouteAnchor(healthKitAnchor: nil)

    public func token() throws -> AnchorToken {
        var object: [String: Any] = [
            "v": 1,
            "offset": deliveredLocations
        ]
        if let healthKitAnchor {
            object["hk"] = healthKitAnchor.base64EncodedString()
        }
        if let pendingRoute {
            object["route"] = pendingRoute.uuidString.lowercased()
        }
        return AnchorToken(
            data: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    public static func decode(_ token: AnchorToken?) throws -> WorkoutRouteAnchor {
        guard let token else {
            return .start
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: token.data)
                as? [String: Any],
            object["v"] as? Int == 1
        else {
            throw WorkoutRouteAnchorError.malformed
        }

        let healthKitAnchor: Data?
        if let encoded = object["hk"] as? String {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw WorkoutRouteAnchorError.malformed
            }
            healthKitAnchor = decoded
        } else {
            healthKitAnchor = nil
        }

        let route = (object["route"] as? String).flatMap(UUID.init(uuidString:))
        if object["route"] != nil, route == nil {
            throw WorkoutRouteAnchorError.malformed
        }

        let offset = object["offset"] as? Int ?? 0
        guard offset >= 0 else {
            throw WorkoutRouteAnchorError.malformed
        }
        // An offset without a route would silently skip the start of whichever
        // route came next, so it is rejected rather than assumed to be zero.
        guard route != nil || offset == 0 else {
            throw WorkoutRouteAnchorError.malformed
        }

        return WorkoutRouteAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingRoute: route,
            deliveredLocations: offset
        )
    }
}
