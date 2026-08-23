import HealthKit
import HozzCatalog

public struct ExportableHealthType: Sendable {
    public let catalogEntry: HealthCatalogEntry
    public let sampleType: HKSampleType

    public init(catalogEntry: HealthCatalogEntry, sampleType: HKSampleType) {
        self.catalogEntry = catalogEntry
        self.sampleType = sampleType
    }
}

/// A characteristic Hozz asks to read.
///
/// Characteristics are not sample types, so they cannot be carried by
/// ``ExportableHealthType``. They are still requested in the same
/// authorization call, because a characteristic Hozz never asked for could
/// only ever come back refused.
public struct AuthorizableCharacteristic: Sendable {
    public let catalogEntry: HealthCatalogEntry
    public let characteristicType: HKCharacteristicType

    public init(
        catalogEntry: HealthCatalogEntry,
        characteristicType: HKCharacteristicType
    ) {
        self.catalogEntry = catalogEntry
        self.characteristicType = characteristicType
    }
}

public enum HealthKitTypeRegistry {
    /// The families Hozz can read and encode as samples today.
    ///
    /// Correlations are deliberately absent. Including them in the standard
    /// authorization request crashes authorization, and querying a type that was
    /// never authorized only produces indeterminate rows, so claiming coverage
    /// for them would be dishonest. Their constituent quantity and category
    /// samples are still exported individually; only the grouping edge is
    /// missing, and it is reported as unsupported.
    ///
    /// Characteristics are absent for a different reason: they are not samples
    /// at all. They are read whole, once per export, by
    /// ``HealthKitCharacteristicsReader`` and listed by ``characteristicTypes``.
    public static func exportableTypes(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [ExportableHealthType] {
        let generated = HealthTypeCatalog.entries.compactMap { entry -> ExportableHealthType? in
            guard entry.introduced.isAvailable(on: operatingSystem) else {
                return nil
            }

            let objectType: HKSampleType?
            switch entry.family {
            case .quantity:
                objectType = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: entry.key.rawValue)
                )
            case .category:
                objectType = HKObjectType.categoryType(
                    forIdentifier: HKCategoryTypeIdentifier(rawValue: entry.key.rawValue)
                )
            case .workout:
                objectType = HKObjectType.workoutType()
            case .audiogram:
                objectType = HKObjectType.audiogramSampleType()
            case .stateOfMind:
                if #available(iOS 18.0, *) {
                    objectType = HKObjectType.stateOfMindType()
                } else {
                    objectType = nil
                }
            case .medication:
                if #available(iOS 26.0, *) {
                    objectType = HKObjectType.medicationDoseEventType()
                } else {
                    objectType = nil
                }
            case .series:
                objectType = switch entry.key.rawValue {
                case WorkoutRouteEncoding.typeIdentifier:
                    HKSeriesType.workoutRoute()
                case ElectrocardiogramEncoding.typeIdentifier:
                    HKObjectType.electrocardiogramType()
                default:
                    nil
                }
            case .clinical:
                // Never, under any build flag. This list feeds
                // `HKAnchoredObjectQuery`, and HealthKit does not support
                // anchored queries for clinical types — so a clinical type
                // reaching it is not a slow path or a wrong result, it is a
                // query that cannot be run. Keeping them structurally out is
                // what makes that unrepresentable rather than merely avoided.
                // They are read by ``HealthKitClinicalRecordReader`` instead,
                // and listed by ``clinicalTypes()``.
                objectType = nil
            case .correlation,
                 .characteristic,
                 .document,
                 .scoredAssessment:
                objectType = nil
            }

            guard let objectType else {
                return nil
            }
            // Per-object authorization keeps types Hozz cannot honestly cover
            // out of the drained set. Clinical records are the one family
            // where it is expected rather than disqualifying, and they are
            // excluded above for a stronger reason anyway.
            guard !objectType.requiresPerObjectAuthorization() else {
                return nil
            }
            return ExportableHealthType(catalogEntry: entry, sampleType: objectType)
        }

        return generated.sorted {
            $0.catalogEntry.key.rawValue < $1.catalogEntry.key.rawValue
        }
    }

    /// The clinical record types, which are only offered when this build can
    /// actually read them.
    ///
    /// They are requested in their own authorization call rather than with
    /// everything else. Someone exporting step counts must never be asked for
    /// their lab results as a side effect of that.
    public static func clinicalTypes(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [ExportableHealthType] {
        guard ClinicalRecordsSupport.isBuiltIn else {
            return []
        }
        // Built here rather than filtered out of `exportableTypes`, so the two
        // lists cannot converge again by someone adding a parameter.
        return HealthTypeCatalog.entries
            .filter { $0.family == .clinical }
            .filter { $0.introduced.isAvailable(on: operatingSystem) }
            .compactMap { entry in
                guard
                    let type = HKObjectType.clinicalType(
                        forIdentifier: HKClinicalTypeIdentifier(
                            rawValue: entry.key.rawValue
                        )
                    )
                else {
                    return nil
                }
                return ExportableHealthType(catalogEntry: entry, sampleType: type)
            }
            .sorted { $0.catalogEntry.key < $1.catalogEntry.key }
    }

    /// The characteristics Hozz reads once per export.
    ///
    /// These are facts about the person — date of birth, biological sex, blood
    /// type, skin type, wheelchair use, move mode — rather than measurements,
    /// so they never appear in the sample stream. They are read whole through
    /// ``HealthKitCharacteristicsReader``.
    public static func characteristicTypes(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [AuthorizableCharacteristic] {
        HealthTypeCatalog.entries
            .filter { $0.family == .characteristic }
            .compactMap { entry -> AuthorizableCharacteristic? in
                guard entry.introduced.isAvailable(on: operatingSystem) else {
                    return nil
                }
                guard
                    let type = HKObjectType.characteristicType(
                        forIdentifier: HKCharacteristicTypeIdentifier(
                            rawValue: entry.key.rawValue
                        )
                    )
                else {
                    return nil
                }
                return AuthorizableCharacteristic(
                    catalogEntry: entry,
                    characteristicType: type
                )
            }
            .sorted { $0.catalogEntry.key < $1.catalogEntry.key }
    }

    /// A type that must never appear in an authorization request, however much
    /// Hozz would like to read it.
    ///
    /// Medication doses are granted per medicine, in Health, under each one's
    /// Data Sources & Access — there is no blanket permission to ask for. Asking
    /// anyway does not return a refusal: HealthKit raises
    /// `NSInvalidArgumentException`, "Authorization to read the following types
    /// is disallowed", and the app is gone before it can report anything. So the
    /// type is drained like any other and simply left out of the request, which
    /// is the arrangement Health expects.
    ///
    /// `requiresPerObjectAuthorization()` does not catch this one, which is why
    /// the guard in `exportableTypes()` lets it through.
    static func isDisallowedInAuthorizationRequest(_ type: HKObjectType) -> Bool {
        guard #available(iOS 26.0, *) else {
            return false
        }
        return type == HKObjectType.medicationDoseEventType()
    }

    /// Every type Hozz reads is requested, except the ones Health refuses to be
    /// asked about. A type Hozz reads but never asks for can only ever report an
    /// indeterminate result, so the read set is the union of the sample types it
    /// drains and the characteristics it fetches, minus those.
    public static func authorizationReadTypes(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Set<HKObjectType> {
        var types = Set<HKObjectType>(
            exportableTypes(operatingSystem: operatingSystem).map(\.sampleType)
        )
        types.formUnion(
            characteristicTypes(operatingSystem: operatingSystem)
                .map(\.characteristicType)
        )
        types = types.filter { !isDisallowedInAuthorizationRequest($0) }
        return types
    }
}
