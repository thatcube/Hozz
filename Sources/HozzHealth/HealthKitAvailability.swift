import HealthKit

public enum HealthKitAvailability {
    public static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
}
