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

public enum HealthKitTypeRegistry {
    /// The families Hozz can read and encode losslessly today.
    ///
    /// Correlations are deliberately absent. Including them in the standard
    /// authorization request crashes authorization, and querying a type that was
    /// never authorized only produces indeterminate rows, so claiming coverage
    /// for them would be dishonest. Their constituent quantity and category
    /// samples are still exported individually; only the grouping edge is
    /// missing, and it is reported as unsupported.
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
            case .correlation,
                 .characteristic,
                 .clinical,
                 .document,
                 .scoredAssessment:
                objectType = nil
            }

            guard let objectType else {
                return nil
            }
            guard !objectType.requiresPerObjectAuthorization() else {
                return nil
            }
            return ExportableHealthType(catalogEntry: entry, sampleType: objectType)
        }

        return generated.sorted {
            $0.catalogEntry.key.rawValue < $1.catalogEntry.key.rawValue
        }
    }

    /// Every exportable type is requested. A type Hozz reads but never asks for
    /// can only ever report an indeterminate result, so the two sets are kept
    /// identical by construction.
    public static func authorizationReadTypes(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Set<HKObjectType> {
        Set(exportableTypes(operatingSystem: operatingSystem).map(\.sampleType))
    }
}
