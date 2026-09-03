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
            "Sync through any Files folder. No server needed."
        case .homeAssistant:
            "Send metrics to Home Assistant sensors."
        case .influxDB:
            "Write line protocol to InfluxDB."
        case .restAPI:
            "POST to your endpoint."
        case .mqtt:
            "Publish to your MQTT broker."
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
                "Choose any folder in Files.",
                "Synced folders reach your computer; local folders stay here.",
                "Send a test."
            ]
        case .homeAssistant:
            [
                "Add a webhook automation or use Home Assistant's REST API.",
                "For REST, create a long-lived access token.",
                "Paste the address here, and put Bearer followed by the token in the field below.",
                "Send a test."
            ]
        case .influxDB:
            [
                "InfluxDB 2.x/3.x: use /api/v2/write with org, bucket, and precision.",
                "InfluxDB 1.8: use /write?db=yourdatabase.",
                "Enter Token, a space, then your API token below.",
                "Match Details precision to the address.",
                "Send a test."
            ]
        case .restAPI:
            [
                "Use any endpoint that accepts POST.",
                "Hozz includes Idempotency-Key for safe retries.",
                "The Hozz repository includes a receiver."
            ]
        case .mqtt:
            [
                "Enter the broker address.",
                "Add credentials if required.",
                "Each metric publishes to hozz/<metric> with its last value retained."
            ]
        }
    }

    /// Anything the user genuinely needs to know before choosing.
    public var caveat: String? {
        switch self {
        case .folder:
            nil
        case .homeAssistant, .restAPI:
            "Your iPhone must be able to reach this address."
        case .influxDB:
            "InfluxDB merges matching measurement, tag, and timestamp points. Your iPhone must reach this address."
        case .mqtt:
            "MQTT keeps no history. Hozz retries while the broker is offline."
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
