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

    // MARK: - The call that actually crashed

    /// Makes the real authorization request, with the real set, against a real
    /// store — which is the call that killed the app on device.
    ///
    /// Health refuses to be *asked* about some types: medication doses are
    /// granted one medicine at a time, so there is no blanket permission to
    /// request, and asking anyway raises `NSInvalidArgumentException` rather
    /// than returning a refusal. The app is gone before it can report
    /// anything. `requiresPerObjectAuthorization()` does not flag that type,
    /// so nothing in the guard caught it.
    ///
    /// Three things make this test worth having rather than a re-statement of
    /// the fix, and each was checked rather than assumed:
    ///
    /// - The simulator raises exactly as the device did, same exception and
    ///   same message naming the offending type.
    /// - The raise is synchronous, so nothing here waits on a completion
    ///   handler that a test host would never see answered.
    /// - XCTest turns the exception into a failing test rather than taking the
    ///   whole run down, so the failure is readable and the suite continues.
    ///
    /// The point is that it names no type. A denylist test can only assert the
    /// one type somebody already found; this fails for the next one too.
    func testTheRealAuthorizationRequestDoesNotRaise() throws {
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "Needs HealthKit."
        )
        let types = HealthKitTypeRegistry.authorizationReadTypes()
        XCTAssertGreaterThan(types.count, 100)

        // No assertion on the outcome: nobody can tap the sheet in a test, so
        // the completion is not the subject. Surviving the call is.
        HKHealthStore().requestAuthorization(toShare: nil, read: types) { _, _ in }
    }

    /// The clinical prompt is a second, separate request, so it needs the same
    /// check. Empty when the feature is compiled out, which asks nothing and
    /// is the honest thing to do with an empty set.
    func testTheClinicalAuthorizationRequestDoesNotRaise() throws {
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "Needs HealthKit."
        )
        let store = HKHealthStore()
        // The gate Apple's own header says to call before requesting
        // authorization for any clinical type. Without it this test raises,
        // which is exactly what it did when it was first written — and what
        // the app would have done on the device.
        try XCTSkipUnless(
            store.supportsHealthRecords(),
            "This build is not entitled for health records, so nothing may ask."
        )
        let types = Set(
            HealthKitTypeRegistry.clinicalTypes().map { $0.sampleType as HKObjectType }
        )
        guard !types.isEmpty else {
            XCTAssertFalse(ClinicalRecordsSupport.isBuiltIn)
            return
        }
        store.requestAuthorization(toShare: nil, read: types) { _, _ in }
    }

    /// The guard that makes the clinical request safe, checked against the
    /// same store the app would use.
    ///
    /// This is the second instance tonight of the same class of bug — asking
    /// HealthKit about something it refuses to be asked about — and it was
    /// found by running the request rather than by reading the code.
    func testNothingAsksAboutClinicalTypesWithoutTheEntitlement() throws {
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "Needs HealthKit."
        )
        let store = HKHealthStore()
        guard !store.supportsHealthRecords() else {
            throw XCTSkip("This build is entitled, so there is nothing to refuse.")
        }

        let availability = ClinicalRecordsSupport.availability(
            isHealthDataAvailable: true,
            supportsHealthRecords: store.supportsHealthRecords()
        )
        XCTAssertFalse(
            availability.canRead,
            """
            Without the entitlement, asking about a clinical type raises and \
            the app dies. Availability must refuse before anything asks.
            """
        )
    }

    /// The type that caused it, held separately so the reason stays written
    /// down even once the general test above is the thing protecting us.
    func testDoseEventsAreDrainedButNeverRequested() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Medication doses need iOS 26.")
        }
        let doses = HKObjectType.medicationDoseEventType()

        XCTAssertTrue(
            HealthKitTypeRegistry.exportableTypes().contains {
                $0.sampleType == doses
            },
            "Doses are still read: only asking about them is fatal."
        )
        XCTAssertFalse(
            HealthKitTypeRegistry.authorizationReadTypes().contains(doses),
            "Asking raises rather than being refused, so it must not be asked."
        )
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
