import Foundation
import HozzCatalog
import HozzCore

/// One reading inside a quantity series.
///
/// HealthKit gives a series reading a date *interval* rather than an instant,
/// and it means it: a cycling power reading is a value sustained over a couple
/// of seconds, not a measurement taken at a point. Both ends are kept, because
/// collapsing them to a midpoint would invent a precision the recorder never
/// claimed.
public struct QuantityReading: Equatable, Sendable, SeriesElement {
    /// The reading, in the type's canonical unit — the same unit the parent
    /// sample's aggregate is written in, so the two compare without conversion.
    public let value: Double
    public let startDate: Date
    public let endDate: Date

    public init(value: Double, startDate: Date, endDate: Date) {
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
    }

    public var seriesTimestamp: Date {
        startDate
    }

    public var seriesObject: [String: any Sendable] {
        [
            "value": value,
            "startDate": SeriesEncoding.timestamp(startDate),
            "endDate": SeriesEncoding.timestamp(endDate)
        ]
    }
}

/// How the readings behind a quantity aggregate are written into an export.
///
/// This is the one series family with no header record of its own. A route or
/// an electrocardiogram is a sample that exists only to own a stream, so the
/// export has to invent a header for it; a quantity series sample is already
/// exported as an ordinary quantity record carrying `count` and
/// `aggregatesSeries`. Writing a second header would be the same sample twice
/// under two identifiers, so the aggregate record *is* the header and the
/// reading pages point back at it by its own UUID.
public enum QuantitySeriesEncoding {
    public static let elementKind = "quantitySeriesReadings"
    public static let endKind = "quantitySeriesEnd"
    public static let elementsKey = "readings"

    /// Readings per record, and records per page.
    ///
    /// A record of 500 readings is roughly 40 KB, and eight of them is a page
    /// of about 320 KB — the same order as an electrocardiogram page, which
    /// the 4 MB pass budget is already sized around.
    public static let readingsPerRecord = 500
    public static let recordsPerPage = 8

    /// The shape for one quantity type.
    ///
    /// Built per type rather than declared once, because the type identifier
    /// is what makes a reading page's identifier unique: the same sample UUID
    /// could never appear under two types, but deriving identifiers from the
    /// type as well keeps this consistent with every other series and costs
    /// nothing.
    public static func shape(for typeIdentifier: String) -> SeriesShape {
        SeriesShape(
            typeIdentifier: typeIdentifier,
            // Never emitted. The parent quantity record is the header.
            headerKind: "quantity",
            elementKind: elementKind,
            endKind: endKind,
            elementsKey: elementsKey,
            elementsPerRecord: readingsPerRecord,
            recordsPerPage: recordsPerPage
        )
    }

    /// Whether a sample Health just handed over has readings worth asking for.
    ///
    /// A count of one is an ordinary measurement, not a series standing for
    /// several, and expanding it would write the same number twice under two
    /// identifiers. A type with no canonical unit cannot have its readings
    /// converted at all, and its aggregate does not encode either.
    public static func isExpandable(count: Int, canonicalUnit: String?) -> Bool {
        count > 1 && canonicalUnit != nil
    }
}
