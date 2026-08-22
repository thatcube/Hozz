import Foundation
import HealthKit
import HozzCore

public enum HealthKitAnchorCodingError: Error, LocalizedError, Sendable {
    case malformedAnchor

    public var errorDescription: String? {
        switch self {
        case .malformedAnchor:
            "Hozz could not read a stored HealthKit cursor."
        }
    }
}

/// Translates between HealthKit's opaque `HKQueryAnchor` and the storable
/// ``AnchorToken`` the rest of Hozz passes around.
///
/// The token stays opaque on purpose. Hozz never interprets, compares ordering
/// on, or derives a date from an anchor's contents; it only stores the exact
/// bytes HealthKit produced and hands them back.
public enum HealthKitAnchorCoding {
    public static func token(for anchor: HKQueryAnchor) throws -> AnchorToken {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
        return AnchorToken(data: data)
    }

    public static func anchor(for token: AnchorToken?) throws -> HKQueryAnchor? {
        guard let token else {
            return nil
        }
        guard
            let anchor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: token.data
            )
        else {
            throw HealthKitAnchorCodingError.malformedAnchor
        }
        return anchor
    }
}
