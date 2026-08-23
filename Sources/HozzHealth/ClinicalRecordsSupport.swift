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
    /// The distinction that matters is the last one. Someone with a hospital
    /// connected to Health, told their records are empty, would reasonably
    /// conclude Hozz had checked and found nothing. It has not checked.
    public enum Availability: Equatable, Sendable {
        /// This build cannot read them, whatever the person has connected.
        case notInThisBuild
        /// Health itself is unavailable or restricted on this device.
        case healthDataUnavailable
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
            case .availableWithPermission:
                "Health will ask which records to share. Hozz exports the ones you choose and cannot see the rest."
            }
        }
    }

    public static func availability(
        isHealthDataAvailable: Bool
    ) -> Availability {
        guard isBuiltIn else {
            return .notInThisBuild
        }
        guard isHealthDataAvailable else {
            return .healthDataUnavailable
        }
        return .availableWithPermission
    }
}
