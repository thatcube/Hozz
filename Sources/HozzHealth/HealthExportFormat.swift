import Foundation

public enum HealthExportFormat: String, CaseIterable, Sendable {
    /// A Zip64 archive holding one NDJSON entry.
    ///
    /// ZIP rather than gzip because a stock Mac opens it by double-click, and
    /// because gzip's 32-bit size field wraps once an export passes 4 GiB.
    case zip
    /// Uncompressed NDJSON, for people who would rather stream it directly.
    case raw

    public var fileExtension: String {
        switch self {
        case .zip:
            "zip"
        case .raw:
            "ndjson"
        }
    }

    /// The extension used for a run's individual, not-yet-joined parts.
    var partFileExtension: String {
        switch self {
        case .zip:
            "deflate"
        case .raw:
            "ndjson"
        }
    }
}
