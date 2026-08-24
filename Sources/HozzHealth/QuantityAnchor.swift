import Foundation
import HozzCore

public enum QuantityAnchorError: Error, LocalizedError, Equatable, Sendable {
    case malformed
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed:
            "Hozz could not read a stored Health cursor."
        case .unsupportedVersion(let version):
            """
            A stored Health cursor was written by a newer version of Hozz \
            (format \(version)) and this one cannot read it.
            """
        }
    }
}

/// Where Hozz is inside an ordinary sample type's stream.
///
/// For almost every type this is nothing more than HealthKit's own opaque
/// anchor, and that is exactly what gets stored: the same bytes, in the same
/// shape, that every cursor written before quantity series expansion existed
/// already holds.
///
/// The exception is a quantity *series*. HealthKit stores some readings as one
/// sample whose `quantity` is an aggregate over `count` values reachable only
/// through `HKQuantitySeriesSampleQuery`, and — unlike a route or an
/// electrocardiogram — there is no predicate for "samples that are series".
/// They can only be noticed while walking the ordinary stream, which means the
/// work of expanding them has to be remembered *here*, in the cursor every
/// type shares, rather than in a series type of its own.
///
/// So the anchor grows a queue: samples already seen at or before
/// ``healthKitAnchor`` whose readings are not yet written, and how far into the
/// first of them Hozz has got. Without that, an export interrupted in the
/// middle of a long series would either replay it or skip the rest of it, and
/// both are what the anchor rule exists to prevent.
///
/// ## Why the encoding has two shapes
///
/// A cursor with nothing pending encodes as the bare HealthKit blob, byte for
/// byte, and not as a JSON object wrapping it. That is deliberate:
///
/// - Every anchor already stored on every device stays valid, unchanged, and
///   is still written back in the shape it arrived in.
/// - The overwhelming majority of types never contain a series at all, and
///   their cursors are never touched by this feature.
/// - A build without this code can still read a cursor a build with it wrote,
///   so long as no expansion was in flight.
public struct QuantityAnchor: Equatable, Sendable {
    /// The exact bytes HealthKit produced. Never interpreted, compared for
    /// ordering, or turned into a date.
    public let healthKitAnchor: Data?
    /// Series samples still to expand, oldest first. The head is the one being
    /// read now.
    public let pendingSeries: [UUID]
    /// How many of the head sample's readings are already durable.
    public let deliveredReadings: Int

    /// Marks the composite shape. A stored HealthKit anchor is an archived
    /// binary plist, so it can never parse as JSON — but naming the format
    /// outright means the two are told apart by what a cursor *says* it is
    /// rather than by a parser happening to fail.
    static let formatName = "hozzQuantityAnchor"
    static let formatVersion = 1

    public init(
        healthKitAnchor: Data?,
        pendingSeries: [UUID] = [],
        deliveredReadings: Int = 0
    ) {
        self.healthKitAnchor = healthKitAnchor
        self.pendingSeries = pendingSeries
        self.deliveredReadings = deliveredReadings
    }

    public static let start = QuantityAnchor(healthKitAnchor: nil)

    /// The sample being expanded, if any.
    public var pendingSample: UUID? {
        pendingSeries.first
    }

    /// The same cursor with the head sample finished and dropped.
    public func advancedPastPendingSample() -> QuantityAnchor {
        QuantityAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingSeries: Array(pendingSeries.dropFirst()),
            deliveredReadings: 0
        )
    }

    /// The same cursor, further into the head sample.
    public func advanced(toReading offset: Int) -> QuantityAnchor {
        QuantityAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingSeries: pendingSeries,
            deliveredReadings: offset
        )
    }

    public func token() throws -> AnchorToken {
        guard !pendingSeries.isEmpty else {
            // Nothing pending, so nothing to say beyond what HealthKit said.
            guard let healthKitAnchor else {
                throw QuantityAnchorError.malformed
            }
            return AnchorToken(data: healthKitAnchor)
        }

        var object: [String: Any] = [
            "format": Self.formatName,
            "v": Self.formatVersion,
            "series": pendingSeries.map { $0.uuidString.lowercased() },
            "offset": deliveredReadings
        ]
        if let healthKitAnchor {
            object["hk"] = healthKitAnchor.base64EncodedString()
        }
        return AnchorToken(
            data: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    public static func decode(_ token: AnchorToken?) throws -> QuantityAnchor {
        guard let token else {
            return .start
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: token.data)
                as? [String: Any],
            let format = object["format"] as? String,
            format == formatName
        else {
            // Anything that is not one of ours is HealthKit's own archived
            // anchor, which is what every cursor written before this feature
            // holds. It is handed back untouched.
            return QuantityAnchor(healthKitAnchor: token.data)
        }

        guard let version = object["v"] as? Int else {
            throw QuantityAnchorError.malformed
        }
        guard version == formatVersion else {
            // A cursor from a newer build. Refusing is the only safe answer:
            // treating it as a HealthKit anchor would crash the unarchiver,
            // and starting over would re-export everything.
            throw QuantityAnchorError.unsupportedVersion(version)
        }

        let healthKitAnchor: Data?
        if let encoded = object["hk"] as? String {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw QuantityAnchorError.malformed
            }
            healthKitAnchor = decoded
        } else {
            healthKitAnchor = nil
        }

        guard let identifiers = object["series"] as? [String] else {
            throw QuantityAnchorError.malformed
        }
        let series = identifiers.compactMap(UUID.init(uuidString:))
        // A queue entry that will not parse is a sample whose readings would
        // never be written and never be noticed again, because the HealthKit
        // anchor has already moved past it. Refusing the cursor keeps it.
        guard series.count == identifiers.count else {
            throw QuantityAnchorError.malformed
        }

        let offset = object["offset"] as? Int ?? 0
        guard offset >= 0 else {
            throw QuantityAnchorError.malformed
        }
        // An offset with no sample would silently skip the start of whichever
        // sample came next, so it is rejected rather than assumed to be zero.
        guard !series.isEmpty || offset == 0 else {
            throw QuantityAnchorError.malformed
        }

        return QuantityAnchor(
            healthKitAnchor: healthKitAnchor,
            pendingSeries: series,
            deliveredReadings: offset
        )
    }
}
