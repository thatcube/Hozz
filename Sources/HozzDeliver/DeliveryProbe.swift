import Foundation

/// The bytes a connection test sends.
///
/// The probe has to be written in the destination's own format. A JSON probe
/// posted to InfluxDB is rejected as unparseable, which would report a
/// correctly configured database as broken and send the user off to debug an
/// address that was right all along — the mirror image of the failure the test
/// exists to prevent.
///
/// It carries no Health data. Whatever the format, the probe says only that
/// something reached the destination.
public enum DeliveryProbe {
    public static let json = #"{"kind":"hozzConnectionTest","schemaVersion":1}"#

    public static func payload(for destination: Destination, now: Date = .now) -> Data {
        switch destination.format {
        case .influx:
            InfluxLineProtocol.probe(options: destination.influxOptions, at: now)
        case .ndjson:
            Data((json + "\n").utf8)
        case .json, .csv, .metrics:
            Data(json.utf8)
        }
    }
}
