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
            case .correlation:
                objectType = HKObjectType.correlationType(
                    forIdentifier: HKCorrelationTypeIdentifier(rawValue: entry.key.rawValue)
                )
            case .workout:
                objectType = HKObjectType.workoutType()
            case .characteristic, .clinical, .document, .scoredAssessment:
                objectType = nil
            }

            guard let objectType else {
                return nil
            }
            return ExportableHealthType(catalogEntry: entry, sampleType: objectType)
        }

        return generated.sorted {
            $0.catalogEntry.key.rawValue < $1.catalogEntry.key.rawValue
        }
    }
}
