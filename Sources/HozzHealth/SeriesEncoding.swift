import CryptoKit
import Foundation
import HozzCatalog
import HozzCore

/// One element of a series: a point on a route, a voltage reading in an ECG.
public protocol SeriesElement: Sendable {
    /// When this element was recorded. Used for the record's own dates, which
    /// the Mac receiver requires before it will store a record at all.
    var seriesTimestamp: Date { get }
    var seriesObject: [String: any Sendable] { get }
}

/// How one series type is written into an export.
///
/// A series sample is written as a header, then a run of element pages, then
/// an end marker. Splitting it up is what keeps a long ride or a full ECG out
/// of memory, and the split is by **absolute offset** rather than by however
/// far a given pass happened to get. That matters: a run interrupted halfway
/// and resumed would otherwise re-chunk the remaining elements differently,
/// give them different identifiers, and land at the receiver as new records
/// rather than as the same ones. Fixed offsets make a replayed page identical
/// to the page it replaces.
public struct SeriesShape: Sendable {
    public let typeIdentifier: String
    public let headerKind: String
    public let elementKind: String
    public let endKind: String
    /// The key elements sit under in an element record.
    public let elementsKey: String
    /// Elements per record. Large enough that a long sample does not become a
    /// million lines, small enough that a handful in flight costs nothing.
    public let elementsPerRecord: Int
    /// Element records handed back in one drain page, which is what bounds how
    /// much of a sample is ever in memory at once.
    public let recordsPerPage: Int

    public init(
        typeIdentifier: String,
        headerKind: String,
        elementKind: String,
        endKind: String,
        elementsKey: String,
        elementsPerRecord: Int,
        recordsPerPage: Int
    ) {
        self.typeIdentifier = typeIdentifier
        self.headerKind = headerKind
        self.elementKind = elementKind
        self.endKind = endKind
        self.elementsKey = elementsKey
        self.elementsPerRecord = elementsPerRecord
        self.recordsPerPage = recordsPerPage
    }

    public var typeKey: HealthTypeKey {
        HealthTypeKey(typeIdentifier)
    }

    /// Elements in one drain page.
    public var elementsPerPage: Int {
        elementsPerRecord * recordsPerPage
    }
}

/// The header of one series sample, captured where HealthKit handed it over.
public struct SeriesHeader: Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    /// The sample's own fields, already encoded.
    ///
    /// Kept as bytes rather than a dictionary because the metadata of an
    /// arbitrary sample is not a `Sendable` value, and the whole point of
    /// encoding inside the query callback is that no `HKSample` escapes
    /// HealthKit's queue.
    public let basePayload: Data

    public init(id: UUID, startDate: Date, endDate: Date, basePayload: Data) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.basePayload = basePayload
    }
}

public struct SeriesPage: Sendable {
    public let header: SeriesHeader?
    public let deletions: [UUID]
    public let anchor: Data

    public init(header: SeriesHeader?, deletions: [UUID], anchor: Data) {
        self.header = header
        self.deletions = deletions
        self.anchor = anchor
    }
}

public struct SeriesFacts: Sendable {
    public let startDate: Date
    public let endDate: Date

    public init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// Builds the records one series sample contributes to an export.
public enum SeriesEncoding {
    public static func headerChange(
        shape: SeriesShape,
        header: SeriesHeader
    ) throws -> HealthChange {
        guard
            var object = try JSONSerialization.jsonObject(with: header.basePayload)
                as? [String: Any]
        else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        object["kind"] = shape.headerKind
        object["schemaVersion"] = 1
        object["catalogVersion"] = HealthTypeCatalog.version
        object["id"] = header.id.uuidString.lowercased()
        object["type"] = shape.typeIdentifier

        return .upsert(
            CapturedHealthObject(
                id: header.id,
                type: shape.typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    /// One page of elements, addressed by its absolute offset in the sample.
    public static func elementsChange(
        shape: SeriesShape,
        sample: UUID,
        offset: Int,
        elements: [any SeriesElement],
        sampleStart: Date,
        sampleEnd: Date
    ) throws -> HealthChange {
        let sequence = offset / shape.elementsPerRecord
        let id = identifier(
            shape: shape,
            sample: sample,
            suffix: "\(shape.elementsKey)-\(sequence)"
        )
        // The receiver requires dates on every record, so a page carries the
        // span of what it holds rather than borrowing the whole sample's.
        let start = elements.first?.seriesTimestamp ?? sampleStart
        let end = elements.last?.seriesTimestamp ?? sampleEnd

        let object: [String: Any] = [
            "kind": shape.elementKind,
            "schemaVersion": 1,
            "id": id.uuidString.lowercased(),
            "type": shape.typeIdentifier,
            "sample": sample.uuidString.lowercased(),
            "sequence": sequence,
            "offset": offset,
            "count": elements.count,
            "startDate": timestamp(start),
            "endDate": timestamp(end),
            shape.elementsKey: elements.map { $0.seriesObject as [String: Any] }
        ]
        return .upsert(
            CapturedHealthObject(
                id: id,
                type: shape.typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    /// Marks a sample as fully written, so a reader can tell a complete one
    /// from one an export never got to the end of.
    public static func endChange(
        shape: SeriesShape,
        sample: UUID,
        elementCount: Int,
        sampleStart: Date,
        sampleEnd: Date
    ) throws -> HealthChange {
        let id = identifier(shape: shape, sample: sample, suffix: "end")
        let object: [String: Any] = [
            "kind": shape.endKind,
            "schemaVersion": 1,
            "id": id.uuidString.lowercased(),
            "type": shape.typeIdentifier,
            "sample": sample.uuidString.lowercased(),
            shape.elementsKey: elementCount,
            "startDate": timestamp(sampleStart),
            "endDate": timestamp(sampleEnd)
        ]
        return .upsert(
            CapturedHealthObject(
                id: id,
                type: shape.typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    /// A stable identifier for a record HealthKit never gave one to.
    ///
    /// Derived from the sample and the record's position, so the same page
    /// always carries the same identifier — which is what lets a receiver
    /// recognise a replayed page as the one it already has.
    public static func identifier(
        shape: SeriesShape,
        sample: UUID,
        suffix: String
    ) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(shape.typeIdentifier.utf8))
        withUnsafeBytes(of: sample.uuid) { hasher.update(data: Data($0)) }
        hasher.update(data: Data(suffix.utf8))
        let digest = Array(hasher.finalize())

        var bytes = Array(digest.prefix(16))
        // Version 5 with the RFC 4122 variant, so the value is a well-formed
        // UUID rather than sixteen arbitrary bytes.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
