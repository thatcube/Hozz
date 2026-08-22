import Foundation
import HozzCore
import HozzDeliver
import HozzStore
import XCTest

/// A channel that can be told to fail, so the retry and backoff behaviour can
/// be exercised without a real network or folder.
private actor ScriptedChannel: DeliveryChannel {
    enum Behaviour: Sendable {
        case succeed
        case fail(DeliveryError)
    }

    private var behaviour: Behaviour
    private(set) var receivedBatchIDs: [UUID] = []

    init(behaviour: Behaviour = .succeed) {
        self.behaviour = behaviour
    }

    func set(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func batchIDs() -> [UUID] {
        receivedBatchIDs
    }

    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        receivedBatchIDs.append(batch.id)
        switch behaviour {
        case .succeed:
            return DeliveryReceipt(
                destinationID: destination.id,
                attemptedAt: .now,
                recordCount: batch.recordCount,
                byteCount: UInt64(batch.payload.count),
                state: .delivered
            )
        case .fail(let error):
            throw error
        }
    }
}

final class DeliveryTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func makeBatch(
        id: UUID = UUID(),
        sequence: Int = 0,
        records: Int = 3
    ) -> DeliveryBatch {
        DeliveryBatch(
            id: id,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordCount: records,
            payload: Data(#"{"kind":"quantity"}"#.utf8),
            format: .ndjson
        )
    }

    private func folderDestination(named name: String = "Test") -> Destination {
        Destination(
            name: name,
            kind: .folder,
            folderBookmark: Data("bookmark".utf8)
        )
    }

    // MARK: - Persistence

    func testDestinationsSurviveAReopen() async throws {
        let store = try makeStore()
        let engine = DeliveryEngine(store: store, channels: [:])
        let destination = folderDestination(named: "My Mac")

        try await engine.save(destination)

        let reopened = DeliveryEngine(store: store, channels: [:])
        let loaded = try await reopened.destinations()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "My Mac")
        XCTAssertEqual(loaded.first?.id, destination.id)
    }

    func testDeletingADestinationRemovesItsState() async throws {
        let store = try makeStore()
        let engine = DeliveryEngine(store: store, channels: [:])
        let destination = folderDestination()
        try await engine.save(destination)

        try await engine.delete(id: destination.id)

        let remaining = try await engine.destinations()
        let state = try await store.deliveryState(for: destination.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(state)
    }

    // MARK: - Delivery outcomes

    func testASuccessfulDeliveryRecordsProgress() async throws {
        let store = try makeStore()
        let channel = ScriptedChannel()
        let engine = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = folderDestination()
        try await engine.save(destination)

        _ = try await engine.deliver(makeBatch(records: 5), to: destination)

        let state = try await engine.state(for: destination.id)
        let receipts = try await engine.receipts(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.delivered.rawValue)
        XCTAssertEqual(state?.deliveredRecords, 5)
        XCTAssertEqual(state?.consecutiveFailures, 0)
        XCTAssertNotNil(state?.lastSuccessAt)
        XCTAssertEqual(receipts.count, 1)
    }

    /// A failure has to be visible. Silent stalling is the single most common
    /// complaint about tools in this space.
    func testAFailedDeliveryIsRecordedAndScheduledForRetry() async throws {
        let store = try makeStore()
        let channel = ScriptedChannel(behaviour: .fail(.transport("offline")))
        let engine = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = folderDestination()
        try await engine.save(destination)

        do {
            _ = try await engine.deliver(makeBatch(), to: destination)
            XCTFail("The delivery should have failed.")
        } catch {
            // Expected.
        }

        let state = try await engine.state(for: destination.id)
        let receipts = try await engine.receipts(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.retrying.rawValue)
        XCTAssertEqual(state?.consecutiveFailures, 1)
        XCTAssertNotNil(state?.nextAttemptAt, "A transient failure must be retried.")
        XCTAssertEqual(receipts.first?.state, DeliveryState.retrying.rawValue)
        XCTAssertNotNil(receipts.first?.detail, "The user must be told why.")
    }

    /// A folder that was deleted will not fix itself, so Hozz stops retrying
    /// and asks the user rather than burning battery forever.
    func testAPermanentFailureIsNotRetriedForever() async throws {
        let store = try makeStore()
        let channel = ScriptedChannel(behaviour: .fail(.accessDenied))
        let engine = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = folderDestination()
        try await engine.save(destination)

        _ = try? await engine.deliver(makeBatch(), to: destination)

        let state = try await engine.state(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.needsAttention.rawValue)
        XCTAssertNil(state?.nextAttemptAt)
    }

    /// The whole point of an idempotency key: a retry has to look like the same
    /// batch, so a receiver that already stored it can discard the repeat.
    func testARetryReusesTheSameBatchIdentifier() async throws {
        let store = try makeStore()
        let channel = ScriptedChannel(behaviour: .fail(.transport("offline")))
        let engine = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = folderDestination()
        try await engine.save(destination)

        let batchID = UUID()
        _ = try? await engine.deliver(makeBatch(id: batchID), to: destination)

        let pending = try await engine.state(for: destination.id)?.pendingBatchID
        XCTAssertEqual(
            pending,
            batchID,
            "The failed batch must stay pending so its identifier is reused."
        )

        await channel.set(.succeed)
        _ = try await engine.deliver(makeBatch(id: batchID), to: destination)

        let seen = await channel.batchIDs()
        XCTAssertEqual(seen, [batchID, batchID])
        let cleared = try await engine.state(for: destination.id)?.pendingBatchID
        XCTAssertNil(cleared, "A delivered batch is no longer pending.")
    }

    func testBackoffGrowsAndThenLevelsOff() {
        let now = Date(timeIntervalSince1970: 0)
        let first = DeliveryEngine.nextAttempt(after: 1, from: now, isTransient: true)
        let second = DeliveryEngine.nextAttempt(after: 2, from: now, isTransient: true)
        let far = DeliveryEngine.nextAttempt(after: 99, from: now, isTransient: true)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!, second!)
        XCTAssertEqual(far, now.addingTimeInterval(DeliveryEngine.backoff.last!))
    }

    // MARK: - Scheduling

    func testAManualDestinationIsNeverDueOnItsOwn() async throws {
        let store = try makeStore()
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = folderDestination()
        destination.cadence = .manual
        try await engine.save(destination)

        let due = try await engine.dueDestinations()
        let forced = try await engine.dueDestinations(ignoringCadence: true)

        XCTAssertTrue(due.isEmpty)
        XCTAssertEqual(forced.count, 1, "Sync Now must override the cadence.")
    }

    func testAnUnconfiguredOrDisabledDestinationIsSkipped() async throws {
        let store = try makeStore()
        let engine = DeliveryEngine(store: store, channels: [:])

        var disabled = folderDestination(named: "Disabled")
        disabled.isEnabled = false
        var unconfigured = Destination(name: "Unfinished", kind: .restAPI)
        unconfigured.endpointURL = nil

        try await engine.save(disabled)
        try await engine.save(unconfigured)

        let due = try await engine.dueDestinations(ignoringCadence: true)
        XCTAssertTrue(due.isEmpty)
    }

    func testAFailedDestinationWaitsForItsBackoff() async throws {
        let store = try makeStore()
        let channel = ScriptedChannel(behaviour: .fail(.transport("offline")))
        let engine = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = folderDestination()
        try await engine.save(destination)

        _ = try? await engine.deliver(makeBatch(), to: destination)

        let due = try await engine.dueDestinations()
        XCTAssertTrue(due.isEmpty, "A destination in backoff must not be retried yet.")

        let later = try await engine.dueDestinations(
            now: Date(timeIntervalSinceNow: 24 * 60 * 60)
        )
        XCTAssertEqual(later.count, 1, "It must be retried once the backoff expires.")
    }

    // MARK: - Type filtering

    func testADestinationOnlyReceivesTheTypesItAskedFor() {
        let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
        let heart = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")
        var destination = folderDestination()
        destination.includedTypes = [steps]

        XCTAssertTrue(destination.includes(steps))
        XCTAssertFalse(destination.includes(heart))

        destination.includedTypes = []
        XCTAssertTrue(
            destination.includes(heart),
            "No selection means everything."
        )
    }

    // MARK: - Credentials

    func testSecretsAreStoredDeviceOnlyAndNeverSynchronised() throws {
        let credentials = DestinationCredentials(
            service: "com.thatcube.Hozz.tests.\(UUID().uuidString)"
        )
        let key = "destination.test"
        defer { try? credentials.delete(for: key) }

        try credentials.save("super-secret-token", for: key)

        XCTAssertEqual(try credentials.secret(for: key), "super-secret-token")
        XCTAssertEqual(
            try credentials.accessibility(for: key),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "A Health destination secret must never leave this device."
        )
    }

    func testDeletingACredentialRemovesIt() throws {
        let credentials = DestinationCredentials(
            service: "com.thatcube.Hozz.tests.\(UUID().uuidString)"
        )
        let key = "destination.test"
        try credentials.save("token", for: key)

        try credentials.delete(for: key)

        XCTAssertNil(try credentials.secret(for: key))
    }

    func testSavingOverAnExistingCredentialReplacesIt() throws {
        let credentials = DestinationCredentials(
            service: "com.thatcube.Hozz.tests.\(UUID().uuidString)"
        )
        let key = "destination.test"
        defer { try? credentials.delete(for: key) }

        try credentials.save("first", for: key)
        try credentials.save("second", for: key)

        XCTAssertEqual(try credentials.secret(for: key), "second")
    }

    // MARK: - Batch naming

    func testBatchFileNamesSortChronologically() {
        let earlier = DeliveryBatch(
            id: UUID(),
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordCount: 1,
            payload: Data(),
            format: .ndjson
        )
        let later = DeliveryBatch(
            id: UUID(),
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            recordCount: 1,
            payload: Data(),
            format: .ndjson
        )

        XCTAssertLessThan(earlier.fileName(), later.fileName())
        XCTAssertTrue(earlier.fileName().hasSuffix(".ndjson"))
    }
}
