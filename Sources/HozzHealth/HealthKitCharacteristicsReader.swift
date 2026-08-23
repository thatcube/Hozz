import Foundation
import HealthKit
import HozzCatalog
import HozzCore

/// Reads the six Health characteristics from a real `HKHealthStore`.
///
/// Characteristics take a different read path from everything else Hozz
/// exports. They are not samples: there is no anchor, no pagination, and no
/// deletion stream, so forcing them through `HKAnchoredObjectQuery` is not an
/// option. Each is fetched whole, on every export, and classified on its own.
///
/// The classification matters more than it looks. HealthKit throws
/// `errorAuthorizationDenied` when a characteristic was refused and
/// `errorNoData` when the person simply never entered one, so unlike sample
/// types these two situations *are* distinguishable — and Hozz reports them
/// apart rather than flattening both into a blank.
public actor HealthKitCharacteristicsReader: HealthCharacteristicsSource {
    private let healthStore: HKHealthStore
    private let operatingSystem: OperatingSystemVersion
    private let now: @Sendable () -> Date

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.healthStore = healthStore
        self.operatingSystem = operatingSystem
        self.now = now
    }

    public func characteristics() async -> HealthCharacteristics {
        guard HKHealthStore.isHealthDataAvailable() else {
            return HealthCharacteristics(
                readAt: now(),
                characteristics: HealthKitTypeRegistry
                    .characteristicTypes(operatingSystem: operatingSystem)
                    .map {
                        .unavailable(
                            $0.catalogEntry.key,
                            reason: "Health data is unavailable on this device."
                        )
                    }
            )
        }

        var results: [HealthCharacteristic] = []
        for characteristic in HealthKitTypeRegistry.characteristicTypes(
            operatingSystem: operatingSystem
        ) {
            results.append(read(characteristic))
        }

        // A characteristic the catalog knows about but this OS predates is
        // still listed, so a reader can tell "not on this OS" from "not asked".
        let read = Set(results.map(\.type))
        for entry in HealthTypeCatalog.entries
        where entry.family == .characteristic && !read.contains(entry.key) {
            results.append(
                .unavailable(
                    entry.key,
                    reason: "\(entry.key.rawValue) needs iOS \(entry.introduced.major).\(entry.introduced.minor)."
                )
            )
        }

        return HealthCharacteristics(readAt: now(), characteristics: results)
    }

    private func read(
        _ characteristic: AuthorizableCharacteristic
    ) -> HealthCharacteristic {
        let key = characteristic.catalogEntry.key
        switch HealthCharacteristicIdentifier(key) {
        case .dateOfBirth:
            return classify(key) {
                let components = try healthStore.dateOfBirthComponents()
                guard
                    let year = components.year,
                    let month = components.month,
                    let day = components.day
                else {
                    // Health answered, but not with a date. Reporting that as
                    // "not set" would claim knowledge Hozz does not have.
                    return .unreadable(
                        key,
                        coverage: .unknown,
                        reason: "Health returned an incomplete date of birth."
                    )
                }
                return .known(
                    key,
                    value: String(
                        format: "%04d-%02d-%02d",
                        year,
                        month,
                        day
                    )
                )
            }

        case .biologicalSex:
            return classify(key) {
                let value = try healthStore.biologicalSex().biologicalSex
                let name: String? = switch value {
                case .notSet: nil
                case .female: "female"
                case .male: "male"
                case .other: "other"
                @unknown default: nil
                }
                return Self.enumeration(
                    key,
                    name: name,
                    rawValue: value.rawValue,
                    notSetRawValue: HKBiologicalSex.notSet.rawValue
                )
            }

        case .bloodType:
            return classify(key) {
                let value = try healthStore.bloodType().bloodType
                let name: String? = switch value {
                case .notSet: nil
                case .aPositive: "A+"
                case .aNegative: "A-"
                case .bPositive: "B+"
                case .bNegative: "B-"
                case .abPositive: "AB+"
                case .abNegative: "AB-"
                case .oPositive: "O+"
                case .oNegative: "O-"
                @unknown default: nil
                }
                return Self.enumeration(
                    key,
                    name: name,
                    rawValue: value.rawValue,
                    notSetRawValue: HKBloodType.notSet.rawValue
                )
            }

        case .fitzpatrickSkinType:
            return classify(key) {
                let value = try healthStore.fitzpatrickSkinType()
                    .skinType
                let name: String? = switch value {
                case .notSet: nil
                case .I: "I"
                case .II: "II"
                case .III: "III"
                case .IV: "IV"
                case .V: "V"
                case .VI: "VI"
                @unknown default: nil
                }
                return Self.enumeration(
                    key,
                    name: name,
                    rawValue: value.rawValue,
                    notSetRawValue: HKFitzpatrickSkinType.notSet.rawValue
                )
            }

        case .wheelchairUse:
            return classify(key) {
                let value = try healthStore.wheelchairUse().wheelchairUse
                let name: String? = switch value {
                case .notSet: nil
                case .no: "no"
                case .yes: "yes"
                @unknown default: nil
                }
                return Self.enumeration(
                    key,
                    name: name,
                    rawValue: value.rawValue,
                    notSetRawValue: HKWheelchairUse.notSet.rawValue
                )
            }

        case .activityMoveMode:
            return classify(key) {
                let value = try healthStore.activityMoveMode().activityMoveMode
                let name: String? = switch value {
                case .activeEnergy: "activeEnergy"
                case .appleMoveTime: "appleMoveTime"
                @unknown default: nil
                }
                // This one has no "not set" case: Health always has a move
                // mode, so an unnamed value can only be a newer one.
                guard let name else {
                    return .unrecognised(key, rawValue: value.rawValue)
                }
                return .known(key, value: name, rawValue: value.rawValue)
            }

        case .none:
            return .unavailable(
                key,
                reason: "Hozz has no reader for \(key.rawValue)."
            )
        }
    }

    /// Turns a HealthKit enumeration into a characteristic without ever
    /// reporting an unnamed value as absent.
    private static func enumeration(
        _ key: HealthTypeKey,
        name: String?,
        rawValue: Int,
        notSetRawValue: Int
    ) -> HealthCharacteristic {
        if let name {
            return .known(key, value: name, rawValue: rawValue)
        }
        if rawValue == notSetRawValue {
            return .notSet(key, rawValue: rawValue)
        }
        return .unrecognised(key, rawValue: rawValue)
    }

    private func classify(
        _ key: HealthTypeKey,
        read: () throws -> HealthCharacteristic
    ) -> HealthCharacteristic {
        do {
            return try read()
        } catch {
            return Self.classify(error, for: key)
        }
    }

    /// Maps a thrown HealthKit error onto an honest characteristic state.
    ///
    /// `errorNoData` is the one case that is *not* a failure: Health answered,
    /// and the answer is that the person never entered this. Refusal comes
    /// back as a distinct authorization error, so treating "no data" as unset
    /// does not quietly absorb a denial.
    static func classify(
        _ error: any Error,
        for key: HealthTypeKey
    ) -> HealthCharacteristic {
        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain,
           nsError.code == HKError.Code.errorNoData.rawValue {
            return .notSet(key)
        }

        let failure = HealthKitFailure.classify(
            error,
            typeIdentifier: key.rawValue
        )
        switch failure.kind {
        case .healthDataUnavailable:
            return .unavailable(
                key,
                reason: failure.underlyingDescription
            )
        default:
            return .unreadable(
                key,
                coverage: failure.coverageState,
                reason: failure.underlyingDescription
            )
        }
    }
}

/// The characteristics Hozz can read, keyed off the catalog identifier.
enum HealthCharacteristicIdentifier: String, CaseIterable, Sendable {
    case activityMoveMode = "HKCharacteristicTypeIdentifierActivityMoveMode"
    case biologicalSex = "HKCharacteristicTypeIdentifierBiologicalSex"
    case bloodType = "HKCharacteristicTypeIdentifierBloodType"
    case dateOfBirth = "HKCharacteristicTypeIdentifierDateOfBirth"
    case fitzpatrickSkinType = "HKCharacteristicTypeIdentifierFitzpatrickSkinType"
    case wheelchairUse = "HKCharacteristicTypeIdentifierWheelchairUse"

    init?(_ key: HealthTypeKey) {
        self.init(rawValue: key.rawValue)
    }
}
