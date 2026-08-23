import Foundation

/// A ready-made destination configuration.
///
/// Several of these are the same channel underneath — Home Assistant is an
/// HTTPS endpoint like any other — but naming them separately is the
/// difference between a capability existing and a capability being found. The
/// most common support question for tools like this is "how do I connect it to
/// Home Assistant", and the honest answer has always been "use the REST
/// option, choose this format, and put `Bearer <token>` in that field". A
/// preset simply does that.
public enum DestinationPreset: String, CaseIterable, Identifiable, Sendable {
    case folder
    case homeAssistant
    case influxDB
    case restAPI
    case mqtt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .folder:
            "Folder"
        case .homeAssistant:
            "Home Assistant"
        case .influxDB:
            "InfluxDB"
        case .restAPI:
            "Web address"
        case .mqtt:
            "MQTT"
        }
    }

    /// One line, aimed at someone deciding rather than someone configuring.
    public var summary: String {
        switch self {
        case .folder:
            "Syncs to your computer through iCloud, Dropbox, or any folder. No server needed."
        case .homeAssistant:
            "Sends metrics straight into Home Assistant as sensors."
        case .influxDB:
            "Writes line protocol straight into InfluxDB, ready to chart in Grafana."
        case .restAPI:
            "Posts to any endpoint you run."
        case .mqtt:
            "Publishes to an MQTT broker on your network."
        }
    }

    public var kind: DestinationKind {
        switch self {
        case .folder:
            .folder
        case .homeAssistant, .influxDB, .restAPI:
            .restAPI
        case .mqtt:
            .mqtt
        }
    }

    public var iconName: String {
        switch self {
        case .folder:
            "folder"
        case .homeAssistant:
            "home"
        case .influxDB:
            "database"
        case .restAPI:
            "api"
        case .mqtt:
            "plug-connected"
        }
    }

    /// Whether Hozz should recommend this first.
    public var isRecommended: Bool {
        self == .folder
    }

    /// The format that works out of the box for this destination.
    public var format: DeliveryFormat {
        switch self {
        case .folder, .restAPI:
            .ndjson
        case .influxDB:
            .influx
        case .homeAssistant, .mqtt:
            // Both want data grouped by metric, and both already understand
            // this shape, so an existing dashboard or automation keeps working.
            .metrics
        }
    }

    public var defaultName: String {
        switch self {
        case .folder:
            "My computer"
        case .homeAssistant:
            "Home Assistant"
        case .influxDB:
            "InfluxDB"
        case .restAPI:
            "My server"
        case .mqtt:
            "MQTT broker"
        }
    }

    /// What goes in the address field, shown as placeholder text.
    public var addressPlaceholder: String {
        switch self {
        case .folder:
            ""
        case .homeAssistant:
            "http://homeassistant.local:8123/api/webhook/hozz"
        case .influxDB:
            "http://influxdb.local:8086/api/v2/write?org=home&bucket=health&precision=ns"
        case .restAPI:
            "https://example.com/health"
        case .mqtt:
            "mqtt://homeassistant.local:1883"
        }
    }

    public var secretPlaceholder: String {
        switch self {
        case .homeAssistant:
            "Bearer <long-lived access token>"
        case .influxDB:
            "Token YOUR_INFLUXDB_API_TOKEN"
        case .restAPI:
            "Authorization header (optional)"
        case .mqtt:
            "Password (optional)"
        case .folder:
            ""
        }
    }

    /// Step-by-step setup, shown inline so nobody has to find a guide.
    public var steps: [String] {
        switch self {
        case .folder:
            [
                "Choose a folder in iCloud Drive, Dropbox, OneDrive, or anywhere the Files app can reach.",
                "Whatever already syncs that folder to your computer does the rest.",
                "Tap Send a test to confirm it works."
            ]
        case .homeAssistant:
            [
                "In Home Assistant, add a webhook trigger automation, or use the REST API.",
                "For the API, create a long-lived access token under your profile.",
                "Paste the address here, and put Bearer followed by the token in the field below.",
                "Tap Send a test — Home Assistant will show the request arriving."
            ]
        case .influxDB:
            [
                "For InfluxDB 2.x or 3.x, use /api/v2/write and add ?org=, ?bucket=, and ?precision= to the address.",
                "For InfluxDB 1.8, use /write?db=yourdatabase instead.",
                "Paste your API token below, written as Token followed by a space and the token itself.",
                "Set the measurement name and timestamp precision under Details; the precision has to match the one in the address.",
                "Tap Send a test — InfluxDB writes one point you can query straight away."
            ]
        case .restAPI:
            [
                "Point this at any endpoint that accepts a POST.",
                "Hozz sends an Idempotency-Key header, so retries are safe to accept twice.",
                "The receiver in the Hozz repository is a working example."
            ]
        case .mqtt:
            [
                "Enter your broker address, for example mqtt://homeassistant.local:1883.",
                "Add a username and password if your broker requires them.",
                "Hozz publishes each metric to hozz/<metric> and retains the last value."
            ]
        }
    }

    /// Anything the user genuinely needs to know before choosing.
    public var caveat: String? {
        switch self {
        case .folder:
            nil
        case .homeAssistant, .restAPI:
            "Your phone has to be able to reach this address. On a home network that means being on the same Wi-Fi."
        case .influxDB:
            "InfluxDB keeps one point per measurement, tag set, and timestamp, so two samples of the same type from the same source at the same instant become one. Your phone also has to be able to reach this address."
        case .mqtt:
            "MQTT keeps no history, so a broker that is offline misses that batch. Hozz retries, but a folder is more forgiving."
        }
    }

    /// Settings this preset starts with, beyond the address and the secret.
    public var options: [String: String] {
        switch self {
        case .influxDB:
            [
                Destination.measurementKey: InfluxLineProtocol.defaultMeasurement,
                Destination.precisionKey: InfluxLineProtocol.Precision.nanoseconds.rawValue
            ]
        case .folder, .homeAssistant, .restAPI, .mqtt:
            [:]
        }
    }

    public func makeDestination() -> Destination {
        Destination(
            name: defaultName,
            kind: kind,
            format: format,
            cadence: .whenDataArrives,
            authorizationHeader: "Authorization",
            options: options
        )
    }
}
