import Foundation
import HozzCore

/// Whether this build of Hozz can read clinical records at all.
///
/// Clinical records need `com.apple.developer.healthkit.access` carrying
/// `health-records`, and Apple grants that entitlement by application. A
/// binary that carries it **before approval is rejected outright**, so it is
/// not in the default build and neither is the code that would ask for it.
///
/// To turn it on once approval lands, two deliberate steps are needed and
/// neither happens by accident:
///
/// 1. Build with `HOZZ_CLINICAL_FLAG=HOZZ_CLINICAL_RECORDS`, which is an
///    undefined build setting by default. Set it on the `xcodebuild` command
///    line or in the gitignored `Local.xcconfig`.
/// 2. Add `health-records` to the `com.apple.developer.healthkit.access`
///    array in `project.yml`, which ships as an empty array.
///
/// Step 1 alone changes no entitlement, so it cannot cause a rejection; it
/// only lets the code compile and report honestly that the entitlement is
/// missing. Step 2 is the one with consequences, which is why it is a visible
/// edit to a tracked file rather than a flag someone can leave switched on.
public enum ClinicalRecordsSupport {
    public static var isBuiltIn: Bool {
        #if HOZZ_CLINICAL_RECORDS
        return true
        #else
        return false
        #endif
    }

    /// Why clinical records are or are not readable right now.
    ///
    /// The build flag and the entitlement are separate switches, and they have
    /// to agree. A build with the flag on and the entitlement absent is not
    /// merely useless: asking HealthKit about a clinical type without the
    /// entitlement raises `NSInvalidArgumentException` and the app is gone
    /// before it can report anything. Apple's answer is
    /// `supportsHealthRecords`, which its own header says to call before
    /// requesting authorization for any clinical type — and which this code
    /// originally did not.
    ///
    /// The distinction that matters is the last one. Someone with a hospital
    /// connected to Health, told their records are empty, would reasonably
    /// conclude Hozz had checked and found nothing. It has not checked.
    public enum Availability: Equatable, Sendable {
        /// This build cannot read them, whatever the person has connected.
        case notInThisBuild
        /// Health itself is unavailable or restricted on this device.
        case healthDataUnavailable
        /// The code is compiled in but this build is not entitled, or the
        /// device does not support health records. Asking anyway would be
        /// fatal, so nothing asks.
        case unsupportedOnThisDevice
        /// Readable, once the person chooses which records to share.
        case availableWithPermission

        public var canRead: Bool {
            self == .availableWithPermission
        }

        /// What to tell someone, in words that do not overstate.
        public var explanation: String {
            switch self {
            case .notInThisBuild:
                "This build of Hozz cannot read health records. It says nothing about whether you have any."
            case .healthDataUnavailable:
                "Health data is unavailable on this device."
            case .unsupportedOnThisDevice:
                "This iPhone cannot share health records with Hozz. It says nothing about whether you have any."
            case .availableWithPermission:
                "Health will ask which records to share. Hozz exports the ones you choose and cannot see the rest."
            }
        }
    }

    /// - Parameter supportsHealthRecords: `HKHealthStore.supportsHealthRecords()`.
    ///   Taken as a parameter rather than read here so the decision can be
    ///   tested for a device that says no, which is every build without the
    ///   entitlement.
    public static func availability(
        isHealthDataAvailable: Bool,
        supportsHealthRecords: Bool
    ) -> Availability {
        guard isBuiltIn else {
            return .notInThisBuild
        }
        guard isHealthDataAvailable else {
            return .healthDataUnavailable
        }
        // The last gate before anything asks HealthKit about a clinical type.
        // Asking when this is false does not fail, it raises.
        guard supportsHealthRecords else {
            return .unsupportedOnThisDevice
        }
        return .availableWithPermission
    }
}
