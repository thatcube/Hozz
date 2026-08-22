import Foundation
import HozzAcquire
import HozzCore
import HozzHealthFake
import XCTest

@MainActor
final class DrainCoordinatorTests: XCTestCase {
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")

    func testDrainPaginatesUntilAnEmptyBatch() async throws {
        let changes = (0..<5).map { index in
            HealthChange.upsert(
                CapturedHealthObject(
                    id: UUID(),
                    type: steps,
                    canonicalPayload: Data("sample-\(index)".utf8)
                )
            )
        }
        let source = ScriptedHealthDataSource(streams: [steps: changes])
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        let report = try await coordinator.drain(type: steps, batchLimit: 2)
        let snapshot = await sink.snapshot(for: steps)
        let queryCount = await source.queryCount(for: steps)

        XCTAssertEqual(report.completion, .anchorClosed)
        XCTAssertEqual(report.queryCount, 4)
        XCTAssertEqual(report.changeCount, 5)
        XCTAssertEqual(queryCount, 4)
        XCTAssertEqual(snapshot.changes, changes)
        XCTAssertNotNil(snapshot.anchorClosedAt)
    }

    func testFailedCommitDoesNotAdvanceTheAnchor() async throws {
        let object = HealthChange.upsert(
            CapturedHealthObject(
                id: UUID(),
                type: steps,
                canonicalPayload: Data("payload".utf8)
            )
        )
        let source = ScriptedHealthDataSource(streams: [steps: [object]])
        let sink = RecordingSink(failNextCommit: true)
        let coordinator = DrainCoordinator(source: source, sink: sink)

        do {
            _ = try await coordinator.drain(type: steps, batchLimit: 10)
            XCTFail("The injected commit failure should escape the drain.")
        } catch RecordingSinkError.injectedCommitFailure {
            // Expected.
        }

        let failedSnapshot = await sink.snapshot(for: steps)
        XCTAssertNil(failedSnapshot.anchor)
        XCTAssertTrue(failedSnapshot.changes.isEmpty)

        let report = try await coordinator.drain(type: steps, batchLimit: 10)
        let recoveredSnapshot = await sink.snapshot(for: steps)

        XCTAssertEqual(report.completion, .anchorClosed)
        XCTAssertEqual(recoveredSnapshot.changes, [object])
    }

    func testPausedDrainResumesFromTheCommittedAnchor() async throws {
        let changes = (0..<6).map { _ in
            HealthChange.upsert(
                CapturedHealthObject(
                    id: UUID(),
                    type: steps,
                    canonicalPayload: Data()
                )
            )
        }
        let source = ScriptedHealthDataSource(streams: [steps: changes])
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        let paused = try await coordinator.drain(
            type: steps,
            batchLimit: 2,
            maximumQueries: 2
        )
        let finished = try await coordinator.drain(type: steps, batchLimit: 2)
        let snapshot = await sink.snapshot(for: steps)

        XCTAssertEqual(paused.completion, .paused)
        XCTAssertEqual(paused.changeCount, 4)
        XCTAssertEqual(finished.completion, .anchorClosed)
        XCTAssertEqual(finished.changeCount, 2)
        XCTAssertEqual(snapshot.changes, changes)
    }

    func testDeletionIsCommittedInStreamOrder() async throws {
        let id = UUID()
        let changes: [HealthChange] = [
            .upsert(
                CapturedHealthObject(
                    id: id,
                    type: steps,
                    canonicalPayload: Data("before-delete".utf8)
                )
            ),
            .delete(CapturedHealthDeletion(id: id, type: steps))
        ]
        let source = ScriptedHealthDataSource(streams: [steps: changes])
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        _ = try await coordinator.drain(type: steps, batchLimit: 1)
        let snapshot = await sink.snapshot(for: steps)

        XCTAssertEqual(snapshot.changes, changes)
    }

    func testSourceFailureDoesNotAdvanceTheAnchor() async throws {
        let change = HealthChange.upsert(
            CapturedHealthObject(id: UUID(), type: steps, canonicalPayload: Data())
        )
        let source = ScriptedHealthDataSource(
            streams: [steps: [change]],
            faults: [steps: [1: .fail]]
        )
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        do {
            _ = try await coordinator.drain(type: steps, batchLimit: 1)
            XCTFail("The injected source failure should escape the drain.")
        } catch ScriptedHealthDataSourceError.injectedFailure {
            // Expected.
        }

        let failedSnapshot = await sink.snapshot(for: steps)
        XCTAssertNil(failedSnapshot.anchor)
        XCTAssertTrue(failedSnapshot.changes.isEmpty)

        let report = try await coordinator.drain(type: steps, batchLimit: 1)
        let recoveredSnapshot = await sink.snapshot(for: steps)

        XCTAssertEqual(report.completion, .anchorClosed)
        XCTAssertEqual(recoveredSnapshot.changes, [change])
    }

    func testNonAdvancingAnchorFailsWithoutDuplicatingACommittedPage() async throws {
        let changes = (0..<2).map { _ in
            HealthChange.upsert(
                CapturedHealthObject(id: UUID(), type: steps, canonicalPayload: Data())
            )
        }
        let source = ScriptedHealthDataSource(
            streams: [steps: changes],
            faults: [steps: [2: .holdAnchor]]
        )
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        do {
            _ = try await coordinator.drain(type: steps, batchLimit: 1)
            XCTFail("A non-empty page with a stalled anchor must fail.")
        } catch DrainError.nonAdvancingAnchor {
            // Expected.
        }

        let snapshot = await sink.snapshot(for: steps)
        XCTAssertEqual(snapshot.changes, [changes[0]])
    }

    func testForeignTypeFailsBeforeCommit() async throws {
        let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")
        let change = HealthChange.upsert(
            CapturedHealthObject(id: UUID(), type: steps, canonicalPayload: Data())
        )
        let source = ScriptedHealthDataSource(
            streams: [steps: [change]],
            faults: [steps: [1: .replaceFirstChangeType(heartRate)]]
        )
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        do {
            _ = try await coordinator.drain(type: steps, batchLimit: 1)
            XCTFail("A page for another Health type must fail.")
        } catch DrainError.unexpectedType(let expected, let actual) {
            XCTAssertEqual(expected, steps)
            XCTAssertEqual(actual, heartRate)
        }

        let snapshot = await sink.snapshot(for: steps)
        XCTAssertNil(snapshot.anchor)
        XCTAssertTrue(snapshot.changes.isEmpty)
    }

    func testCancelledDrainReturnsWithoutQueryingOrCommitting() async throws {
        let change = HealthChange.upsert(
            CapturedHealthObject(id: UUID(), type: steps, canonicalPayload: Data())
        )
        let source = ScriptedHealthDataSource(streams: [steps: [change]])
        let sink = RecordingSink()
        let coordinator = DrainCoordinator(source: source, sink: sink)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.drain(type: steps, batchLimit: 1)
        }
        let report = try await task.value
        let snapshot = await sink.snapshot(for: steps)
        let queryCount = await source.queryCount(for: steps)

        XCTAssertEqual(report.completion, .cancelled)
        XCTAssertNil(report.finalAnchor)
        XCTAssertEqual(queryCount, 0)
        XCTAssertNil(snapshot.anchor)
        XCTAssertTrue(snapshot.changes.isEmpty)
    }

    func testInvalidHealthTypeKeyDecodeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(HealthTypeKey.self, from: Data("\"\"".utf8))
        )
    }
}

private enum RecordingSinkError: Error {
    case injectedCommitFailure
    case staleBaseAnchor
}

private actor RecordingSink: DurableHealthChangeSink {
    struct Snapshot: Sendable {
        let anchor: AnchorToken?
        let changes: [HealthChange]
        let anchorClosedAt: Date?
    }

    private var anchors: [HealthTypeKey: AnchorToken] = [:]
    private var changes: [HealthTypeKey: [HealthChange]] = [:]
    private var anchorClosedAt: [HealthTypeKey: Date] = [:]
    private var failNextCommit: Bool

    init(failNextCommit: Bool = false) {
        self.failNextCommit = failNextCommit
    }

    func committedAnchor(for type: HealthTypeKey) async throws -> AnchorToken? {
        anchors[type]
    }

    func commit(
        _ batch: HealthChangeBatch,
        for type: HealthTypeKey,
        baseAnchor: AnchorToken?
    ) async throws {
        guard anchors[type] == baseAnchor else {
            throw RecordingSinkError.staleBaseAnchor
        }
        if failNextCommit {
            failNextCommit = false
            throw RecordingSinkError.injectedCommitFailure
        }

        changes[type, default: []].append(contentsOf: batch.changes)
        anchors[type] = batch.proposedAnchor
    }

    func markAnchorClosed(
        type: HealthTypeKey,
        anchor: AnchorToken,
        observedChangeCount: Int,
        hadPriorAnchor: Bool,
        at date: Date
    ) async throws {
        guard anchors[type] == anchor else {
            throw RecordingSinkError.staleBaseAnchor
        }
        precondition(observedChangeCount >= 0)
        _ = hadPriorAnchor
        anchorClosedAt[type] = date
    }

    func snapshot(for type: HealthTypeKey) -> Snapshot {
        Snapshot(
            anchor: anchors[type],
            changes: changes[type, default: []],
            anchorClosedAt: anchorClosedAt[type]
        )
    }
}
