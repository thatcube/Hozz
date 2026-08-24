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
    /// An MQTT broker, for home automation setups.
    case mqtt

    public var displayName: String {
        switch self {
        case .folder:
            "Folder"
        case .restAPI:
            "REST API"
        case .mqtt:
            "MQTT"
        }
    }

    public var requiresNetwork: Bool {
        self != .folder
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
    /// Records grouped by metric with the latest value per point.
    ///
    /// This is the shape home-automation and dashboard tools expect, and it
    /// happens to match the schema other Apple Health exporters emit, so an
    /// existing Home Assistant integration or Grafana dashboard keeps working
    /// when pointed at Hozz. The compatibility is documented rather than
    /// advertised in the interface: it is a reason this shape was chosen, not
    /// a feature to sell.
    case metrics
    /// InfluxDB line protocol, which InfluxDB and Telegraf ingest directly.
    ///
    /// Self-hosters charting Health data in Grafana were deploying a container
    /// whose only job was translating an exporter's JSON into this. Writing it
    /// here removes that container from the diagram.
    case influx

    public var displayName: String {
        switch self {
        case .ndjson:
            "NDJSON"
        case .json:
            "JSON"
        case .csv:
            "CSV"
        case .metrics:
            "Metrics JSON"
        case .influx:
            "InfluxDB line protocol"
        }
    }

    public var fileExtension: String {
        switch self {
        case .ndjson:
            "ndjson"
        case .json, .metrics:
            "json"
        case .csv:
            "csv"
        case .influx:
            "lp"
        }
    }

    public var contentType: String {
        switch self {
        case .ndjson:
            "application/x-ndjson"
        case .json, .metrics:
            "application/json"
        case .csv:
            "text/csv"
        case .influx:
            // What InfluxDB's own write API expects.
            "text/plain; charset=utf-8"
        }
    }

    /// Whether the format keeps every field Health returned.
    public var isLossless: Bool {
        self == .ndjson || self == .json
    }

    /// The formats worth offering for a destination of this kind.
    ///
    /// Line protocol is deliberately missing from folders. Hozz's own Mac app
    /// watches a folder for `ndjson`, `json`, and `csv` batches and ignores
    /// anything else, so a folder destination writing line protocol would
    /// appear to be working while the Mac quietly ingested nothing. An endpoint
    /// answers for itself, which is why it is offered there.
    public static func available(for kind: DestinationKind) -> [DeliveryFormat] {
        switch kind {
        case .folder:
            [.ndjson, .json, .csv, .metrics]
        case .restAPI, .mqtt:
            allCases
        }
    }
}

/// Which field names and shape a delivery uses.
///
/// Hozz's own schema is the default and the one that is documented. The
/// alternative exists because the paid app most people are leaving has a
/// published format, and their Home Assistant automations, MQTT subscribers,
/// and scripts are all keyed to its field names. Making someone rewrite all of
/// that to switch is a real reason not to switch.
public enum PayloadSchema: String, Codable, CaseIterable, Sendable {
    /// Hozz's documented schema.
    case hozz
    /// Health Auto Export's published field names, for pipelines already built
    /// against them.
    case healthAutoExport

    public var displayName: String {
        switch self {
        case .hozz:
            "Hozz"
        case .healthAutoExport:
            "Health Auto Export"
        }
    }

    /// Whether this schema changes anything for the given format.
    ///
    /// Only the grouped-by-metric shape has a counterpart worth matching. The
    /// record-per-line formats are Hozz's own and there is nothing to be
    /// compatible with.
    public static func applies(to format: DeliveryFormat) -> Bool {
        format == .metrics
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
    /// Which field names the payload uses.
    public var payloadSchema: PayloadSchema
    /// How far back this destination is willing to be sent.
    ///
    /// A delivery filter, not an acquisition cursor. See ``DeliveryWindow``.
    public var deliveryWindow: DeliveryWindow
    /// Per-destination settings that are neither secrets nor HTTP headers —
    /// the InfluxDB measurement name, for instance.
    ///
    /// Kept apart from ``headers`` because those really are sent as headers,
    /// and a measurement name arriving as one would be noise at best.
    public var options: [String: String]
    /// Settings that were persisted with a value this build does not recognise,
    /// keyed by the field they came from and holding the original word.
    ///
    /// Not a key of its own on disk. It is derived when a stored destination is
    /// read and consumed when one is written, which is what lets an unknown
    /// setting survive a round trip through a build that cannot use it.
    public private(set) var unsupportedSettings: [String: String] = [:]
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
        payloadSchema: PayloadSchema = .hozz,
        deliveryWindow: DeliveryWindow = .sinceLastDelivery,
        options: [String: String] = [:],
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
        self.payloadSchema = payloadSchema
        self.deliveryWindow = deliveryWindow
        self.options = options
        self.createdAt = createdAt
    }

    /// Decodes tolerantly, so a row written by an older build still loads.
    ///
    /// The synthesised decoder would throw on a payload missing a key added
    /// later, and destinations are loaded with `try?`. Between those two facts,
    /// adding one field would have silently emptied everybody's destination
    /// list on upgrade — the delivery equivalent of losing records. Every field
    /// is therefore optional on the way in and falls back to its default.
    /// Declared rather than synthesised, so ``unsupportedSettings`` never
    /// becomes a key of its own on disk. It is derived from the other fields
    /// and writing it down would let it disagree with them.
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, format, cadence, isEnabled, folderBookmark
        case endpointURL, headers, authorizationHeader, includedTypes
        case payloadSchema, deliveryWindow, options, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        endpointURL = try container.decodeIfPresent(URL.self, forKey: .endpointURL)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
            ?? [:]
        authorizationHeader = try container.decodeIfPresent(
            String.self,
            forKey: .authorizationHeader
        ) ?? "Authorization"
        includedTypes = try container.decodeIfPresent(
            Set<HealthTypeKey>.self,
            forKey: .includedTypes
        ) ?? []
        options = try container.decodeIfPresent([String: String].self, forKey: .options)
            ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now

        // Every enum is read as text first. `decodeIfPresent` returns nil only
        // for an absent or null key; a value the enum does not recognise
        // *throws*, and destinations are loaded with `try?`, so one unknown
        // word would have deleted the whole destination from the user's list
        // with no error at all.
        var unsupported: [String: String] = [:]
        func value<T: RawRepresentable<String>>(
            _ key: CodingKeys,
            _ fallback: T
        ) throws -> T {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
                return fallback
            }
            guard let known = T(rawValue: raw) else {
                // Kept, not guessed at. The raw word is written back out
                // untouched by `encode(to:)`, so a build that does not
                // understand this setting cannot destroy it either.
                unsupported[key.stringValue] = raw
                return fallback
            }
            return known
        }

        kind = try value(.kind, .folder)
        format = try value(.format, .ndjson)
        cadence = try value(.cadence, .whenDataArrives)
        payloadSchema = try value(.payloadSchema, .hozz)
        // The fallback is the unbounded window on purpose. If this build cannot
        // read the window that was chosen, the destination is parked as
        // unusable anyway — but should that ever change, the setting that
        // cannot leave a record out is the safer thing to be wrong about.
        deliveryWindow = try value(.deliveryWindow, .sinceLastDelivery)

        // The InfluxDB precision is not an enum on the way in — it is a string
        // in `options` — so it cannot throw. It can do something worse:
        // silently fall back to nanoseconds and file every point in the wrong
        // decade, in a database that will not complain.
        if let raw = options[Destination.precisionKey],
           InfluxLineProtocol.Precision(rawValue: raw) == nil {
            unsupported[Destination.precisionKey] = raw
        }

        unsupportedSettings = unsupported
    }

    /// Writes the original word back for anything this build did not recognise.
    ///
    /// This is the half that makes keeping the record mean something. Without
    /// it, the first time anything re-saved the destination — a delivery
    /// receipt, a folder bookmark refresh — the fallback would be written over
    /// the user's real setting and their choice would be gone for good, with
    /// the upgrade that could have understood it arriving too late.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(folderBookmark, forKey: .folderBookmark)
        try container.encodeIfPresent(endpointURL, forKey: .endpointURL)
        try container.encode(headers, forKey: .headers)
        try container.encode(authorizationHeader, forKey: .authorizationHeader)
        try container.encode(includedTypes, forKey: .includedTypes)
        try container.encode(options, forKey: .options)
        try container.encode(createdAt, forKey: .createdAt)

        try container.encode(
            unsupportedSettings[CodingKeys.kind.stringValue] ?? kind.rawValue,
            forKey: .kind
        )
        try container.encode(
            unsupportedSettings[CodingKeys.format.stringValue] ?? format.rawValue,
            forKey: .format
        )
        try container.encode(
            unsupportedSettings[CodingKeys.cadence.stringValue] ?? cadence.rawValue,
            forKey: .cadence
        )
        try container.encode(
            unsupportedSettings[CodingKeys.payloadSchema.stringValue]
                ?? payloadSchema.rawValue,
            forKey: .payloadSchema
        )
        try container.encode(
            unsupportedSettings[CodingKeys.deliveryWindow.stringValue]
                ?? deliveryWindow.rawValue,
            forKey: .deliveryWindow
        )
    }

    /// Whether Hozz understands this destination well enough to use it.
    ///
    /// A destination set up by a newer build, or by one whose vocabulary has
    /// since changed, is kept and shown rather than deleted or quietly run with
    /// substituted settings. Sending someone's Health data somewhere in a shape
    /// they did not choose is not a smaller failure than losing the
    /// destination; it is a larger one, because it looks like it worked.
    public var isUsable: Bool {
        unsupportedSettings.isEmpty
    }

    /// What to tell the user, when there is something to tell them.
    public var unsupportedDescription: String? {
        guard !unsupportedSettings.isEmpty else {
            return nil
        }
        let described = unsupportedSettings
            .sorted { $0.key < $1.key }
            .map { "\(Destination.settingName(for: $0.key)) \u{201C}\($0.value)\u{201D}" }
        let list: String
        switch described.count {
        case 1:
            list = described[0]
        case 2:
            list = "\(described[0]) and \(described[1])"
        default:
            list = described.dropLast().joined(separator: ", ")
                + ", and \(described[described.count - 1])"
        }
        return "This destination uses \(list), which this version of Hozz does "
            + "not understand. Nothing has been sent to it, and the setting has "
            + "been kept. Update Hozz, or edit the destination to choose a "
            + "setting this version supports."
    }

    static func settingName(for key: String) -> String {
        switch key {
        case CodingKeys.kind.stringValue:
            "a destination type"
        case CodingKeys.format.stringValue:
            "a format"
        case CodingKeys.cadence.stringValue:
            "a schedule"
        case CodingKeys.payloadSchema.stringValue:
            "a field-name scheme"
        case CodingKeys.deliveryWindow.stringValue:
            "a limit on how far back to send"
        case Destination.precisionKey:
            "a timestamp precision"
        default:
            "a setting"
        }
    }

    /// The InfluxDB measurement and timestamp precision for this destination.
    public var influxOptions: InfluxLineProtocol.Options {
        InfluxLineProtocol.Options(
            measurement: options[Destination.measurementKey]
                ?? InfluxLineProtocol.defaultMeasurement,
            precision: options[Destination.precisionKey]
                .flatMap(InfluxLineProtocol.Precision.init(rawValue:)) ?? .nanoseconds
        )
    }

    public static let measurementKey = "influxMeasurement"
    public static let precisionKey = "influxPrecision"
    public static let timeoutKey = "requestTimeout"
    /// Set while this destination is owed a replay of its whole history.
    ///
    /// Widening a delivery window has to do two things — write the new window,
    /// and clear the cursors so the readings the narrower one skipped are read
    /// again — and they are two separate writes to two separate tables. If the
    /// second never happens, because the process was killed or the write failed,
    /// nothing afterwards can tell: the destination already holds the wider
    /// window, so comparing old against new says no replay is due, and the
    /// readings are lost for good.
    ///
    /// The marker is written *with* the new window, in the same record, before
    /// the cursors are touched. Whatever happens next, the fact that a replay is
    /// owed is on disk, and it is acted on and cleared the next time the engine
    /// loads or saves. Clearing cursors twice does nothing, so acting on it more
    /// often than necessary is harmless; acting on it less often is the failure
    /// this exists to prevent.
    public static let pendingReplayKey = "pendingReplay"
    public static let maxRequestBytesKey = "maxRequestBytes"
    /// The concrete date a bounded delivery window resolved to.
    ///
    /// Written when the user chooses the window and then left alone, so the
    /// starting point stops moving. A date worked out afresh at delivery time
    /// creeps forward between the moment a reading was read and the moment it is
    /// sent, and everything it creeps past is excluded permanently while the
    /// delivery is reported as complete — which throws away every night's sleep,
    /// every night, on a destination set to start from today.
    public static let windowFloorKey = "windowFloor"

    /// The starting point actually in force for this destination.
    ///
    /// Unbounded when the window is ``DeliveryWindow/sinceLastDelivery``, and
    /// also when a bounded window has no resolved date yet — because admitting
    /// too much costs a duplicate a receiver can recognise, and admitting too
    /// little costs a reading nobody sees again.
    public var deliveryFloor: DeliveryFloor {
        guard deliveryWindow.isBounded else {
            return .unbounded
        }
        return DeliveryFloor(
            date: options[Destination.windowFloorKey]
                .flatMap(InfluxLineProtocol.date(from:))
        )
    }

    /// The largest body this destination should be sent in one request, or nil
    /// to send each batch whole however large it is.
    ///
    /// The limit that bites in practice is a server's, not a phone's: an nginx
    /// in front of somebody's home API refuses a body over one megabyte by
    /// default and takes the whole batch down with it. Splitting is off unless
    /// asked for, because it changes how many requests an already-working
    /// destination receives, and a setup that works should keep working
    /// untouched across an update.
    public var maxRequestBytes: Int? {
        guard
            let raw = options[Destination.maxRequestBytesKey],
            let bytes = Int(raw),
            bytes >= RequestSize.minimum
        else {
            return nil
        }
        return bytes
    }

    /// Whether this destination still owes its history a replay.
    public var isReplayPending: Bool {
        options[Destination.pendingReplayKey] != nil
    }

    /// How long to wait for a destination to answer before giving up.
    ///
    /// A fixed timeout strands the people this app is for. A Raspberry Pi
    /// running Home Assistant on an SD card can take minutes to accept a large
    /// batch, and `URLSession`'s default of sixty seconds turns that into a
    /// permanent, unexplained failure. Equally, a phone waiting an hour on a
    /// server that is switched off is a phone spending battery on nothing, so
    /// the choice belongs to the person who knows which of the two they have.
    ///
    /// Stored as a string in ``options`` rather than as a number, because that
    /// is the only shape `options` has. An unreadable or out-of-range value
    /// falls back to the default rather than being treated as unsupported: a
    /// timeout cannot silently change the *meaning* of what is delivered, only
    /// how long Hozz waits, so parking the destination over it would cost the
    /// user their data to protect them from nothing.
    public var requestTimeout: TimeInterval {
        guard
            let raw = options[Destination.timeoutKey],
            let seconds = TimeInterval(raw),
            RequestTimeout.range.contains(seconds)
        else {
            return RequestTimeout.default
        }
        return seconds
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
        case .restAPI, .mqtt:
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
    /// A replacement bookmark, when the folder's stored one went stale. Carried
    /// on the receipt rather than held on the channel, because one channel
    /// serves every destination of its kind.
    public let refreshedBookmark: Data?

    public init(
        destinationID: UUID,
        attemptedAt: Date,
        recordCount: Int,
        byteCount: UInt64,
        state: DeliveryState,
        detail: String? = nil,
        artifactName: String? = nil,
        refreshedBookmark: Data? = nil
    ) {
        self.destinationID = destinationID
        self.attemptedAt = attemptedAt
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.state = state
        self.detail = detail
        self.artifactName = artifactName
        self.refreshedBookmark = refreshedBookmark
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
    ///
    /// The destination is part of the name because two destinations may point
    /// at the same folder, and every batch in one pass shares a timestamp and
    /// starts at sequence zero. Without it their first files would be named
    /// identically and the second would silently replace the first.
    public func fileName(prefix: String = "hozz", destinationID: UUID? = nil) -> String {
        let stamp = Date.ISO8601FormatStyle(timeZone: .gmt)
            .format(createdAt)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let owner = destinationID.map {
            "-" + $0.uuidString.lowercased().prefix(8)
        } ?? ""
        return "\(prefix)-\(stamp)\(owner)-\(String(format: "%06d", sequence)).\(format.fileExtension)"
    }
}

public enum DeliveryError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    /// The stored destination uses a setting this build does not recognise.
    case unsupportedSettings(String)
    /// A delivery window was set, but this build could not take the encoded
    /// batch apart to apply it.
    ///
    /// Delivering the batch whole would have sent readings the user asked to
    /// exclude, which is the failure that looks like a success.
    case windowNotApplicable
    /// A batch split across several requests stopped partway.
    ///
    /// Its own case rather than the underlying failure, because the two are not
    /// the same fact and the difference is the one the user needs. "The server
    /// refused the data" and "the server took the first two of five and then
    /// refused" call for different things to be checked, and nothing else in
    /// the system can reconstruct the second from the first.
    ///
    /// Nothing is recorded as delivered either way: the acquisition cursor does
    /// not move, and the whole batch is sent again from the first part. The
    /// parts that did land carry the same bytes and therefore the same
    /// idempotency key, so a receiver that honours it stores them once.
    case incompleteBatch(accepted: Int, total: Int, detail: String, isTransient: Bool)
    case folderUnavailable
    case accessDenied
    case rejected(statusCode: Int, body: String?)
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "This destination is not finished being set up."
        case .unsupportedSettings(let detail):
            detail
        case .windowNotApplicable:
            "Hozz could not tell how old the readings in this batch were, so "
                + "it sent nothing rather than send readings you asked it to "
                + "leave out."
        case .incompleteBatch(let accepted, let total, let detail, _):
            "This batch was sent in \(total) requests and the destination "
                + "accepted \(accepted) of them before stopping. \(detail) "
                + "Nothing has been counted as delivered, and the whole batch "
                + "will be sent again from the beginning."
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
        case .incompleteBatch(_, _, _, let isTransient):
            // Carried through from whatever stopped it. A split delivery that
            // failed on a 500 deserves the same patience as an unsplit one.
            isTransient
        case .notConfigured, .folderUnavailable, .accessDenied, .cancelled,
             .unsupportedSettings, .windowNotApplicable:
            // Waiting does not teach this build a word it does not know. Only
            // an update or an edit resolves it, so it is put in front of the
            // user instead of retried on a timer forever.
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
