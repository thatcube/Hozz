import Foundation
import HozzCore

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
    /// GPX 1.1 tracks, one file per workout that has GPS.
    ///
    /// Not a projection of the export like the others: it is a *filter*. A GPX
    /// file holds a route and nothing else, so this exports only workouts with
    /// a route and none of the rest of Health. It exists because GPX is what
    /// every mapping and fitness tool reads, and a route delivered as JSON is
    /// of no use to someone moving to a self-hosted Strava.
    case gpx
    /// Uncompressed NDJSON, for piping straight into something else.
    case raw

    /// The Health types a run in this format needs to read.
    ///
    /// `nil` means everything Hozz can read, which is the right answer for
    /// every format that presents the whole of Health.
    ///
    /// A format that is a *filter* rather than a projection has no reason to
    /// drain the rest. A GPX file holds a route and nothing else, so reading
    /// two hundred types to write out a handful of tracks spends someone's
    /// afternoon producing a file that could not have contained the
    /// difference. A manual export's cursors are scoped to its own run, so a
    /// restricted run cannot advance a cursor any other run or destination
    /// depends on — which is what makes narrowing safe rather than merely
    /// faster.
    public var requiredTypes: Set<HealthTypeKey>? {
        switch self {
        case .gpx:
            [
                HealthTypeKey("HKWorkoutTypeIdentifier"),
                WorkoutRouteEncoding.typeKey
            ]
        case .ndjson, .csv, .json, .markdown, .sqlite, .raw:
            nil
        }
    }

    public var fileExtension: String {
        switch self {
        case .ndjson, .csv, .json, .markdown, .gpx:
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
        case .ndjson, .csv, .json, .markdown, .sqlite, .gpx:
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
        case .csv, .json, .markdown, .sqlite, .gpx, .raw:
            false
        }
    }

    /// Whether the format cannot carry everything the export holds.
    ///
    /// All three are lossy on purpose — a grid and a daily note are for
    /// reading rather than for keeping, and a GPX file is a route — and all
    /// three say so where the format is chosen.
    public var isLossy: Bool {
        self == .csv || self == .markdown || self == .gpx
    }

    /// Whether the format exports only workouts that have a route.
    ///
    /// This is a different thing from being lossy, and worth its own name. The
    /// others take everything in the export and keep less of each record; this
    /// one takes almost nothing in the export and keeps all of what it takes.
    /// Someone choosing it expecting a health export gets an archive that looks
    /// broken, so the interface has to say which it is before they pick it.
    public var coversRoutesOnly: Bool {
        self == .gpx
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
        case .gpx:
            "GPX"
        case .raw:
            "Raw NDJSON"
        }
    }
}
