import Foundation

public enum HealthExportFormat: String, CaseIterable, Sendable {
    case gzip
    case raw

    public var fileExtension: String {
        switch self {
        case .gzip:
            "ndjson.gz"
        case .raw:
            "ndjson"
        }
    }
}
