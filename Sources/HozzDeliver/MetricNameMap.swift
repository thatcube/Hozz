import HozzCore

/// Maps HealthKit identifiers to the shared grouped-payload namespace.
public enum MetricNameMap {
    public static func metricName(for identifier: String) -> String {
        CompatibilityMetricName.name(for: identifier)
    }

    public static func typeIdentifier(for metricName: String) -> String? {
        CompatibilityMetricName.typeIdentifier(for: metricName)
    }
}
