import Foundation

public enum HealthExportFormat: String, CaseIterable, Sendable {
    /// Newline-delimited JSON: one record per line, lossless, and streamable at
    /// any size. The internal spool always uses this, so it costs nothing.
    case ndjson
    /// One CSV per data type. Opens in Excel or Sheets, and is explicitly a
    /// lossy projection: metadata, device details, and nested workout events do
    /// not fit a grid.
    case csv
    /// A single JSON array. Convenient for small exports and awkward for large
    /// ones, since most tools load the whole array into memory.
    case json
    /// One SQLite database, ready to be queried. Not lossy: the typed columns
    /// are a projection for querying and every row keeps its original record.
    case sqlite
    /// Uncompressed NDJSON, for piping straight into something else.
    case raw

    public var fileExtension: String {
        switch self {
        case .ndjson, .csv, .json:
            "zip"
        case .sqlite:
            "sqlite"
        case .raw:
            "ndjson"
        }
    }

    /// The extension used for a run's individual, not-yet-assembled parts.
    var partFileExtension: String {
        switch self {
        case .ndjson, .csv, .json, .sqlite:
            "deflate"
        case .raw:
            "ndjson"
        }
    }

    /// Whether the archive can be assembled by copying compressed parts rather
    /// than reading and rewriting every record.
    var copiesPartsVerbatim: Bool {
        switch self {
        case .ndjson:
            true
        case .csv, .json, .sqlite, .raw:
            false
        }
    }

    public var isLossy: Bool {
        self == .csv
    }

    public var displayName: String {
        switch self {
        case .ndjson:
            "NDJSON"
        case .csv:
            "CSV"
        case .json:
            "JSON"
        case .sqlite:
            "SQLite"
        case .raw:
            "Raw NDJSON"
        }
    }
}
