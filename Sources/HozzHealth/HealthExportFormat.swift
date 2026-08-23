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
    /// One Markdown note per day, for a journal. Explicitly lossy: a note
    /// keeps a day's totals, never the records they were derived from.
    case markdown
    /// One SQLite database, ready to be queried. Not lossy: the typed columns
    /// are a projection for querying and every row keeps its original record.
    case sqlite
    /// Uncompressed NDJSON, for piping straight into something else.
    case raw

    public var fileExtension: String {
        switch self {
        case .ndjson, .csv, .json, .markdown:
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
        case .ndjson, .csv, .json, .markdown, .sqlite:
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
        case .csv, .json, .markdown, .sqlite, .raw:
            false
        }
    }

    /// Whether the format cannot carry everything the export holds.
    ///
    /// Both of these are lossy on purpose — a grid and a daily note are for
    /// reading, not for keeping — and both say so where the format is chosen.
    public var isLossy: Bool {
        self == .csv || self == .markdown
    }

    public var displayName: String {
        switch self {
        case .ndjson:
            "NDJSON"
        case .csv:
            "CSV"
        case .json:
            "JSON"
        case .markdown:
            "Markdown"
        case .sqlite:
            "SQLite"
        case .raw:
            "Raw NDJSON"
        }
    }
}
