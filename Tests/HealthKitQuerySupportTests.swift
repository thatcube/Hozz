import HealthKit
import HozzCatalog
import HozzCore
import XCTest
@testable import HozzHealth

/// The tests that would have caught the crash.
///
/// The existing clinical tests drive value types and a fake source, so they can
/// say nothing about whether a query HealthKit refuses to run was constructed.
/// These use a real `HKHealthStore` on the simulator. No records come back —
/// nothing is authorised and the simulator has no provider — but "does this
/// query run at all" is answerable without any, and it is the exact question
/// that went unasked.
final class HealthKitQuerySupportTests: XCTestCase {
    /// The invariant the crash violated: everything the drain iterates must be
    /// something an anchored query can serve.
    ///
    /// This is the structural half. The list is built without clinical types at
    /// all, so no build flag can put one back.
    func testNothingInTheDrainNeedsAQueryHealthKitCannotRun() {
        for exportable in HealthKitTypeRegistry.exportableTypes() {
            XCTAssertFalse(
                exportable.sampleType is HKClinicalType,
                """
                \(exportable.catalogEntry.key.rawValue) is a clinical type in \
                the anchored drain. HealthKit does not support anchored \
                queries for these, so this is a crash rather than a bad result.
                """
            )
            XCTAssertNotEqual(
                exportable.catalogEntry.family,
                .clinical,
                "A clinical catalogue entry must never reach the drained list."
            )
        }
    }

    func testTheDrainStaysClearOfClinicalTypesUnderEveryBuild() {
        // `exportableTypes` no longer takes a parameter that could admit them,
        // which is what makes this true rather than merely currently true.
        let drained = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.key)
        )
        let clinical = Set(
            HealthTypeCatalog.entries
                .filter { $0.family == .clinical }
                .map(\.key)
        )

        XCTAssertFalse(clinical.isEmpty, "The catalogue still knows about them.")
        XCTAssertTrue(
            drained.isDisjoint(with: clinical),
            "The two lists must not converge again."
        )
    }

    /// Runs the real query the drain runs, against a real store, for every
    /// type the drain would visit. Authorisation is undetermined on a
    /// simulator so every one comes back with an error rather than data — but
    /// an unsupported query fails differently from an unauthorised one, and
    /// only one of those can be checked without a device.
    func testEveryDrainedTypeCanHaveItsQueryConstructedAndRun() async throws {
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "Needs HealthKit."
        )
        let store = HKHealthStore()
        let source = HealthKitHealthDataSource(healthStore: store)

        // A sample across the list rather than all 195, so this stays a quick
        // check rather than a two-minute one. Series types are included
        // deliberately: they take a different path inside the source.
        let types = HealthKitTypeRegistry.exportableTypes()
        let sampled = stride(from: 0, to: types.count, by: 12)
            .map { types[$0] }
            + [
                types.first { $0.catalogEntry.family == .series },
                types.first { $0.catalogEntry.family == .workout }
            ].compactMap { $0 }

        for type in sampled {
            do {
                _ = try await source.changes(
                    for: type.catalogEntry.key,
                    after: nil,
                    limit: 1
                )
            } catch {
                // An authorisation error is the expected simulator answer and
                // says the query ran. Anything else is the class of failure
                // that reached a device untested.
                let failure = HealthKitFailure.classify(error)
                XCTAssertEqual(
                    failure.kind,
                    .authorizationIndeterminate,
                    """
                    \(type.catalogEntry.key.rawValue) failed with \
                    \(failure.underlyingDescription) rather than an \
                    authorisation error, which means the query itself is the \
                    problem.
                    """
                )
            }
        }
    }

    /// Clinical records read through `HKSampleQuery`, and this proves that
    /// query is constructible for every clinical type.
    func testEveryClinicalTypeCanBeReadWithASampleQuery() async throws {
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "Needs HealthKit."
        )
        // Built directly rather than through the registry, so this runs
        // whether or not the feature is compiled in — the query support is a
        // fact about HealthKit, not about our build flag.
        let types = HealthTypeCatalog.entries
            .filter { $0.family == .clinical }
            .compactMap { entry -> ExportableHealthType? in
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
        XCTAssertEqual(types.count, 9)

        let backend = HealthKitClinicalRecordBackend()
        for type in types {
            do {
                _ = try await backend.records(of: type)
            } catch {
                let failure = HealthKitFailure.classify(error)
                XCTAssertEqual(
                    failure.kind,
                    .authorizationIndeterminate,
                    """
                    \(type.catalogEntry.key.rawValue) could not be read with a \
                    sample query: \(failure.underlyingDescription)
                    """
                )
            }
        }
    }

    /// The build flag has to actually change the build.
    ///
    /// It was set on the app target while the code it gates lives in the
    /// HozzHealth framework, so it compiled nothing differently — and every
    /// run claimed to cover "both configurations" was the same build twice.
    /// This fails if the flag is inert again.
    func testTheClinicalBuildFlagReachesTheCodeItGates() {
        #if HOZZ_CLINICAL_RECORDS
        XCTAssertTrue(
            ClinicalRecordsSupport.isBuiltIn,
            """
            The test target sees the flag but HozzHealth does not, so the \
            flag is set somewhere that does not reach the framework.
            """
        )
        XCTAssertEqual(HealthKitTypeRegistry.clinicalTypes().count, 9)
        #else
        XCTAssertFalse(ClinicalRecordsSupport.isBuiltIn)
        XCTAssertTrue(HealthKitTypeRegistry.clinicalTypes().isEmpty)
        #endif
    }
}
