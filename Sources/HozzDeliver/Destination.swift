import CryptoKit
import Foundation
import HozzCore

/// Where a user has asked Hozz to send their Health data.
///
/// Hozz has no default destination and no maintainer-operated server. Nothing
/// leaves the device until one of these exists and the user has confirmed it.
public enum DestinationKind: String, Codable, CaseIterable, Sendable {
    /// A folder chosen with the system file picker. Covers iCloud Drive,
    /// Dropbox, OneDrive, Google Drive, an SMB share, or on-device storage —
    /// iOS presents them all through the same interface.
    ///
    /// This is the default because it needs no server, no open ports, and no
    /// VPN, and because the sync client already installed on the user's
    /// computer does the networking. It also keeps working while that computer
    /// is switched off, which a push to a local receiver cannot.
    case folder
    /// An HTTPS endpoint the user runs. For people who want the data in a
    /// database rather than in files.
    case restAPI

    public var displayName: String {
        switch self {
        case .folder:
            "Folder"
        case .restAPI:
            "REST API"
        }
    }

    public var requiresNetwork: Bool {
        self == .restAPI
    }
}

/// How often a destination should receive data.
///
/// These are requests, not guarantees. iOS decides when a background app runs,
/// and Health cannot be read at all while the device is locked.
public enum SyncCadence: String, Codable, CaseIterable, Sendable {
    /// Deliver as soon as iOS wakes Hozz for new data. Most types are capped at
    /// hourly by HealthKit regardless of what is asked for.
    case whenDataArrives
    case hourly
    case daily
    /// Only when the user asks, or when a Shortcut runs.
    case manual

    public var displayName: String {
        switch self {
        case .whenDataArrives:
            "When new data arrives"
        case .hourly:
            "About every hour"
        case .daily:
            "About once a day"
        case .manual:
            "Only when I ask"
        }
    }

    /// The shortest gap Hozz will leave between two deliveries.
    public var minimumInterval: TimeInterval {
        switch self {
        case .whenDataArrives:
            5 * 60
        case .hourly:
            55 * 60
        case .daily:
            23 * 60 * 60
        case .manual:
            .infinity
        }
    }
}

/// The shape of the payload a destination receives.
public enum DeliveryFormat: String, Codable, CaseIterable, Sendable {
    case ndjson
    case json
    case csv
    /// The payload shape used by the widely deployed Health Auto Export
    /// schema, so existing Home Assistant integrations, Grafana dashboards,
    /// and community ingest servers keep working when pointed at Hozz.
    case compatible

    public var displayName: String {
        switch self {
        case .ndjson:
            "NDJSON"
        case .json:
            "JSON"
        case .csv:
            "CSV"
        case .compatible:
            "Health Auto Export compatible"
        }
    }

    public var fileExtension: String {
        switch self {
        case .ndjson:
            "ndjson"
        case .json, .compatible:
            "json"
        case .csv:
            "csv"
        }
    }

    public var contentType: String {
        switch self {
        case .ndjson:
            "application/x-ndjson"
        case .json, .compatible:
            "application/json"
        case .csv:
            "text/csv"
        }
    }

    /// Whether the format keeps every field Health returned.
    public var isLossless: Bool {
        self == .ndjson || self == .json
    }
}

/// A configured destination.
///
/// Secrets are deliberately absent: a bearer token lives in the Keychain under
/// ``credentialKey`` and is never written to the database, a backup, or a log.
public struct Destination: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: DestinationKind
    public var format: DeliveryFormat
    public var cadence: SyncCadence
    public var isEnabled: Bool
    /// Security-scoped bookmark for a folder destination.
    public var folderBookmark: Data?
    /// Endpoint for a REST destination.
    public var endpointURL: URL?
    /// Header names and values that carry no secret. The token, if any, is
    /// merged in from the Keychain at send time.
    public var headers: [String: String]
    /// Header the Keychain token is sent in. Defaults to `Authorization`.
    public var authorizationHeader: String
    /// Types the user chose to sync. Empty means everything Hozz can read.
    public var includedTypes: Set<HealthTypeKey>
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DestinationKind,
        format: DeliveryFormat = .ndjson,
        cadence: SyncCadence = .whenDataArrives,
        isEnabled: Bool = true,
        folderBookmark: Data? = nil,
        endpointURL: URL? = nil,
        headers: [String: String] = [:],
        authorizationHeader: String = "Authorization",
        includedTypes: Set<HealthTypeKey> = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.format = format
        self.cadence = cadence
        self.isEnabled = isEnabled
        self.folderBookmark = folderBookmark
        self.endpointURL = endpointURL
        self.headers = headers
        self.authorizationHeader = authorizationHeader
        self.includedTypes = includedTypes
        self.createdAt = createdAt
    }

    /// Keychain account name for this destination's secret.
    public var credentialKey: String {
        "destination.\(id.uuidString.lowercased())"
    }

    public func includes(_ type: HealthTypeKey) -> Bool {
        includedTypes.isEmpty || includedTypes.contains(type)
    }

    /// Whether the destination has everything it needs to run.
    public var isConfigured: Bool {
        switch kind {
        case .folder:
            folderBookmark != nil
        case .restAPI:
            endpointURL != nil
        }
    }
}

/// What happened the last time Hozz tried to deliver.
///
/// Background work is best effort, so these states are deliberately explicit
/// rather than collapsing into "synced" and "error".
public enum DeliveryState: String, Codable, Hashable, Sendable {
    /// Nothing has been attempted yet.
    case idle
    /// There is data to send and Hozz is waiting for iOS to run it.
    case waitingForSystem
    /// A delivery is in flight.
    case delivering
    /// Everything staged has been accepted by the destination.
    case delivered
    /// The device was locked, so Health could not be read. Resolves itself.
    case waitingForUnlock
    /// The destination rejected the data or could not be reached. Will retry.
    case retrying
    /// Something the user has to fix, such as a folder that was moved.
    case needsAttention

    public var isHealthy: Bool {
        switch self {
        case .idle, .waitingForSystem, .delivering, .delivered, .waitingForUnlock:
            true
        case .retrying, .needsAttention:
            false
        }
    }
}

/// The outcome of one delivery attempt.
public struct DeliveryReceipt: Codable, Hashable, Sendable {
    public let destinationID: UUID
    public let attemptedAt: Date
    public let recordCount: Int
    public let byteCount: UInt64
    public let state: DeliveryState
    public let detail: String?
    /// Where the batch landed, when that is meaningful to show.
    public let artifactName: String?

    public init(
        destinationID: UUID,
        attemptedAt: Date,
        recordCount: Int,
        byteCount: UInt64,
        state: DeliveryState,
        detail: String? = nil,
        artifactName: String? = nil
    ) {
        self.destinationID = destinationID
        self.attemptedAt = attemptedAt
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.state = state
        self.detail = detail
        self.artifactName = artifactName
    }
}

/// One batch of changes, ready to hand to a destination.
public struct DeliveryBatch: Sendable {
    /// Stable across retries, so a destination can discard a repeat.
    public let id: UUID
    public let sequence: Int
    public let createdAt: Date
    public let recordCount: Int
    public let payload: Data
    public let format: DeliveryFormat

    public init(
        id: UUID,
        sequence: Int,
        createdAt: Date,
        recordCount: Int,
        payload: Data,
        format: DeliveryFormat
    ) {
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.recordCount = recordCount
        self.payload = payload
        self.format = format
    }

    /// A key derived from the bytes being sent.
    ///
    /// Idempotency only works if the same key always means the same content. A
    /// retry that re-read Health and picked up newer records is a *different*
    /// batch, and reusing the previous key for it would let a correctly written
    /// receiver discard records it had never seen.
    public static func identifier(for payload: Data) -> UUID {
        var digest = SHA256()
        digest.update(data: payload)
        let bytes = Array(digest.finalize())
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    /// A name that sorts chronologically and never collides.
    public func fileName(prefix: String = "hozz") -> String {
        let stamp = Date.ISO8601FormatStyle(timeZone: .gmt)
            .format(createdAt)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        return "\(prefix)-\(stamp)-\(String(format: "%06d", sequence)).\(format.fileExtension)"
    }
}

public enum DeliveryError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case folderUnavailable
    case accessDenied
    case rejected(statusCode: Int, body: String?)
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "This destination is not finished being set up."
        case .folderUnavailable:
            "Hozz could not reach that folder. It may have been moved, renamed, or signed out."
        case .accessDenied:
            "Hozz no longer has permission to write to that folder."
        case .rejected(let statusCode, let body):
            "The destination refused the data (HTTP \(statusCode))."
                + (body.map { ": \($0)" } ?? "")
        case .transport(let detail):
            "Hozz could not reach the destination: \(detail)"
        case .cancelled:
            "The delivery was stopped before it finished."
        }
    }

    /// Whether waiting and trying again could succeed without user action.
    public var isTransient: Bool {
        switch self {
        case .transport:
            true
        case .rejected(let statusCode, _):
            // 408, 429, and 5xx are the server asking to be tried again.
            statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .notConfigured, .folderUnavailable, .accessDenied, .cancelled:
            false
        }
    }

    public var deliveryState: DeliveryState {
        switch self {
        case .cancelled:
            .waitingForSystem
        default:
            isTransient ? .retrying : .needsAttention
        }
    }
}

/// Somewhere a batch can be sent.
public protocol DeliveryChannel: Sendable {
    func deliver(_ batch: DeliveryBatch, to destination: Destination) async throws -> DeliveryReceipt
}
