import Foundation
@testable import HozzReceive
import HozzStore
import XCTest

final class FolderIngestWatcherTests: XCTestCase {
    private actor EventCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    private actor AuditRecorder {
        private var cycles: [(files: Int, bytes: UInt64)] = []

        func record(files: Int, bytes: UInt64) {
            cycles.append((files, bytes))
        }

        func reset() {
            cycles.removeAll()
        }

        func recordedCycles() -> [(files: Int, bytes: UInt64)] {
            cycles
        }
    }

    private final class FakeFileSystem:
        FolderIngestFileSystem,
        @unchecked Sendable
    {
        struct Counts {
            let fullListings: Int
            let pageRequests: Int
            let metadataNames: Set<String>
        }

        private let lock = NSLock()
        private var names: [String] = []
        private var pageOffset = 0
        private var fullListings = 0
        private var pageRequests = 0
        private var metadataNames: Set<String> = []
        private var contentGenerationAvailable = true
        private var payloads: [String: Data] = [:]

        func replaceNames(_ names: [String]) {
            lock.lock()
            self.names = names
            pageOffset = 0
            lock.unlock()
        }

        func resetCounts() {
            lock.lock()
            fullListings = 0
            pageRequests = 0
            metadataNames.removeAll()
            lock.unlock()
        }

        func setContentGenerationAvailable(_ available: Bool) {
            lock.lock()
            contentGenerationAvailable = available
            lock.unlock()
        }

        func replacePayload(_ data: Data, for name: String) {
            lock.lock()
            payloads[name] = data
            lock.unlock()
        }

        func data(for name: String) -> Data {
            lock.lock()
            defer { lock.unlock() }
            return payloadLocked(for: name)
        }

        func counts() -> Counts {
            lock.lock()
            defer { lock.unlock() }
            return Counts(
                fullListings: fullListings,
                pageRequests: pageRequests,
                metadataNames: metadataNames
            )
        }

        func allNames(in folder: URL) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            fullListings += 1
            pageOffset = 0
            return names
        }

        func nextNamePage(in folder: URL, limit: Int) -> FolderDirectoryPage {
            lock.lock()
            defer { lock.unlock() }
            pageRequests += 1
            guard pageOffset < names.count else {
                pageOffset = 0
                return FolderDirectoryPage(names: [], completedCycle: true)
            }
            let end = min(pageOffset + limit, names.count)
            let page = Array(names[pageOffset..<end])
            pageOffset = end == names.count ? 0 : end
            return FolderDirectoryPage(
                names: page,
                completedCycle: end == names.count
            )
        }

        func generation(of url: URL) -> FolderFileGeneration? {
            lock.lock()
            metadataNames.insert(url.lastPathComponent)
            let exists = names.contains(url.lastPathComponent)
            let data = payloadLocked(for: url.lastPathComponent)
            let contentGeneration = contentGenerationAvailable
                ? Data(("generation-" + url.lastPathComponent).utf8)
                : nil
            lock.unlock()
            guard exists else {
                return nil
            }
            return FolderFileGeneration(
                size: UInt64(data.count),
                modified: Date(timeIntervalSince1970: 1),
                resourceIdentifier: Data(url.lastPathComponent.utf8),
                contentGeneration: contentGeneration
            )
        }

        func isSettled(_ url: URL) -> Bool {
            true
        }

        func read(_ url: URL) throws -> Data {
            data(for: url.lastPathComponent)
        }

        func resetPaging() {
            lock.lock()
            pageOffset = 0
            lock.unlock()
        }

        private func payloadLocked(for name: String) -> Data {
            payloads[name] ?? Data(
                """
                {"id":"\(name)","type":"steps","kind":"quantity",\
                "startDate":"2026-01-01T10:00:00.000Z",\
                "quantity":{"value":1,"unit":"count"}}

                """.utf8
            )
        }
    }

    func testMalformedCompatibilityFileRemainsRetryableAtTheSameName() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-retry-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )
        let file = folder.appending(path: "batch.json")
        try Data(#"{"data":{"metrics":["#.utf8).write(to: file)
        try settle(file)

        await watcher.start(folder: folder)
        let rejectedCount = try await store.totalRecordCount()
        XCTAssertEqual(rejectedCount, 0)

        try Data(
            """
            {"data":{"metrics":[{"name":"steps","units":"count","data":[
              {"id":"fixed","date":"2026-01-01T10:00:00.000Z","qty":1}
            ]}]}}
            """.utf8
        ).write(to: file)
        try settle(file)
        var importedCount = 0
        for _ in 0..<30 {
            importedCount = try await store.totalRecordCount()
            if importedCount == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(importedCount, 1)
        await watcher.stop()
        await store.close()
    }

    func testUnchangedMalformedFileIsNotRetriedForever() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-bounded-retry-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )
        let counter = EventCounter()
        await watcher.onEvent { event in
            if case .rejected = event.outcome {
                Task { await counter.increment() }
            }
        }
        let file = folder.appending(path: "bad.json")
        try Data(#"{"data":{"metrics":["#.utf8).write(to: file)
        try settle(file)

        await watcher.start(folder: folder)
        try await Task.sleep(for: .milliseconds(2_500))

        let eventCount = await counter.count
        XCTAssertEqual(eventCount, 1)
        await watcher.stop()
        await store.close()
    }

    func testAppendingAndReplacingSuccessfulFileIngestsEveryGeneration() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-generations-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )
        let file = folder.appending(path: "batch.ndjson")
        try sample(id: "first", hour: 10).write(to: file)
        try settle(file)

        await watcher.start(folder: folder)
        let initialCount = try await store.totalRecordCount()
        XCTAssertEqual(initialCount, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: sample(id: "appended", hour: 11))
        try handle.close()
        try settle(file)
        let appendedCount = try await waitForCount(2, in: store)
        XCTAssertEqual(appendedCount, 2)

        try sample(id: "replacement", hour: 12).write(to: file, options: .atomic)
        try settle(file)

        let ids = try await waitForIDs(
            ["first", "appended", "replacement"],
            in: store
        )
        XCTAssertEqual(ids, ["first", "appended", "replacement"])
        await watcher.stop()
        await store.close()
    }

    func testMutationAfterVerificationIsPickedUpAsANewGeneration() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-mutation-window-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let replacement = sample(id: "after-verification", hour: 11)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100),
            didVerifySnapshot: { file in
                try? replacement.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date.now.addingTimeInterval(-2)],
                    ofItemAtPath: file.path
                )
            }
        )
        let file = folder.appending(path: "batch.ndjson")
        try sample(id: "verified", hour: 10).write(to: file)
        try settle(file)
        await watcher.start(folder: folder)

        let ids = try await waitForIDs(
            ["verified", "after-verification"],
            in: store
        )
        XCTAssertEqual(ids, ["verified", "after-verification"])
        await watcher.stop()
        await store.close()
    }

    func testReplacedLegacyFilenameImportsNewStableRecord() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-replaced-name-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        _ = try await store.ingest(
            try BatchParser.parse(sample(id: "original", hour: 10)),
            idempotencyKey: "batch.ndjson"
        )
        let file = folder.appending(path: "batch.ndjson")
        var replacement = sample(id: "replaced", hour: 11)
        replacement.append(
            Data(
                #"{"id":"original","type":"steps","kind":"deletion","deleted":true}"#
                    .utf8
            )
        )
        try replacement.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let ids = try await waitForIDs(["replaced"], in: store)
        XCTAssertEqual(ids, ["replaced"])
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameReceiptDoesNotDowngradeNewerValue() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-receipt-bridge-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let oldPayload = sample(id: "shared", hour: 10, value: 1)
        _ = try await store.ingest(
            try BatchParser.parse(oldPayload),
            idempotencyKey: "batch.ndjson"
        )
        _ = try await store.ingest(
            try BatchParser.parse(sample(id: "shared", hour: 10, value: 99)),
            idempotencyKey: "newer-network-delivery"
        )
        let file = folder.appending(path: "batch.ndjson")
        try oldPayload.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        var samples = try await store.samples(type: "steps")
        var shared = samples.first { $0.id == "shared" }
        XCTAssertEqual(shared?.value, 99)

        try sample(id: "next-generation", hour: 11).write(
            to: file,
            options: .atomic
        )
        try settle(file)
        let ids = try await waitForIDs(["shared", "next-generation"], in: store)
        XCTAssertEqual(ids, ["shared", "next-generation"])
        samples = try await store.samples(type: "steps")
        shared = samples.first { $0.id == "shared" }
        XCTAssertEqual(shared?.value, 99)
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameCanonicalWorkoutSupersedesCompatibilitySampleAndDetail() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-workout-precedence-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let compatibility = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"folder-workout","name":"Running",
               "start":"2026-01-01T10:00:00.000Z",
               "end":"2026-01-01T11:01:00.000Z",
               "duration":3660,"source":"Legacy Exporter"}
            ]}}
            """.utf8
        )
        _ = try await store.ingest(
            try BatchParser.parse(compatibility),
            idempotencyKey: "workout.ndjson"
        )
        let canonical = Data(
            #"{"kind":"workout","id":"folder-workout","type":"HKWorkoutTypeIdentifier","startDate":"2026-01-01T10:00:00.123Z","endDate":"2026-01-01T11:00:00.987Z","activityType":37,"duration":3599.75,"statistics":[],"source":{"name":"Apple Watch"}}"#.utf8
        )
        let file = folder.appending(path: "workout.ndjson")
        try canonical.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let compatibilitySamples = try await store.samples(type: "workout")
        let canonicalSamples = try await store.samples(
            type: "HKWorkoutTypeIdentifier"
        )
        XCTAssertTrue(compatibilitySamples.isEmpty)
        XCTAssertEqual(canonicalSamples.map(\.id), ["folder-workout"])
        XCTAssertEqual(canonicalSamples.first?.value, 3_599.75)
        XCTAssertEqual(canonicalSamples.first?.sourceName, "Apple Watch")
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
        let workouts = try await store.workouts()
        XCTAssertEqual(workouts.map(\.id), ["folder-workout"])
        XCTAssertEqual(workouts.first?.activityType, 37)
        XCTAssertEqual(workouts.first?.duration, 3_599.75)
        XCTAssertEqual(workouts.first?.sourceName, "Apple Watch")
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameCanonicalWorkoutCleansMixedUpgradeRowsBeforeReceipt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-workout-upgrade-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let compatibility = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"workouts":[
                  {"id":"mixed-workout","name":"Running",
                   "start":"2026-01-01T10:00:00.000Z",
                   "end":"2026-01-01T11:01:00.000Z",
                   "duration":3660,"source":"Legacy Exporter"}
                ]}}
                """.utf8
            )
        )
        _ = try await store.ingest(
            compatibility,
            idempotencyKey: "initial-compatibility"
        )
        let canonical = Data(
            #"{"kind":"workout","id":"mixed-workout","type":"HKWorkoutTypeIdentifier","startDate":"2026-01-01T10:00:00.123Z","endDate":"2026-01-01T11:00:00.987Z","activityType":37,"duration":3599.75,"statistics":[],"source":{"name":"Apple Watch"}}"#.utf8
        )
        let canonicalBatch = try BatchParser.parse(canonical)
        let canonicalRecord = try XCTUnwrap(canonicalBatch.records.first)
        _ = try await store.ingest(
            ParsedBatch(
                records: [canonicalRecord],
                deletions: [],
                unreadableCount: 0
            ),
            idempotencyKey: "canonical-sample-only"
        )
        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: canonicalRecord.id,
                        type: "Running",
                        kind: "workout",
                        startDate: canonicalRecord.startDate,
                        endDate: canonicalRecord.endDate,
                        value: canonicalRecord.value,
                        unit: canonicalRecord.unit,
                        sourceName: "Upgrade alias",
                        raw: Data()
                    )
                ],
                deletions: [],
                unreadableCount: 0
            ),
            idempotencyKey: "mixed-workout.ndjson"
        )
        let before = try await store.workouts()
        XCTAssertEqual(before.first?.sourceName, "Legacy Exporter")
        let countBeforeCleanup = try await store.totalRecordCount()
        XCTAssertEqual(countBeforeCleanup, 2)
        let file = folder.appending(path: "mixed-workout.ndjson")
        try canonical.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let canonicalSamples = try await store.samples(
            type: "HKWorkoutTypeIdentifier"
        )
        let aliases = try await store.samples(type: "Running")
        XCTAssertEqual(canonicalSamples.map(\.id), ["mixed-workout"])
        XCTAssertTrue(aliases.isEmpty)
        let after = try await store.workouts()
        XCTAssertEqual(after.first?.activityType, 37)
        XCTAssertEqual(after.first?.duration, 3_599.75)
        XCTAssertEqual(after.first?.sourceName, "Apple Watch")
        await watcher.stop()
        await store.close()
        try assertOneFolderHashReceipt(in: root)
    }

    func testLegacyFilenameCompatibilityRepairsExactAliasBeforeReceipt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-exact-workout-alias-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let payload = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"alias-workout","name":"Running",
               "start":"2026-01-01T10:00:00.000Z",
               "end":"2026-01-01T11:00:00.000Z",
               "duration":3600,"source":"Legacy Exporter"}
            ]}}
            """.utf8
        )
        let compatibility = try BatchParser.parse(payload)
        let record = try XCTUnwrap(compatibility.records.first)
        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: record.id,
                        type: "Running",
                        kind: "workout",
                        startDate: record.startDate,
                        endDate: record.endDate,
                        value: record.value,
                        unit: record.unit,
                        sourceName: record.sourceName,
                        raw: record.raw
                    )
                ],
                deletions: [],
                workoutDetails: compatibility.workoutDetails,
                unreadableCount: 0
            ),
            idempotencyKey: "alias-workout.ndjson"
        )
        let file = folder.appending(path: "alias-workout.ndjson")
        try payload.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let aliases = try await store.samples(type: "Running")
        let current = try await store.samples(type: "workout")
        XCTAssertTrue(aliases.isEmpty)
        XCTAssertEqual(current.map(\.id), ["alias-workout"])
        let workouts = try await store.workouts()
        XCTAssertEqual(workouts.map(\.id), ["alias-workout"])
        XCTAssertEqual(workouts.first?.duration, 3_600)
        await watcher.stop()
        await store.close()
        try assertOneFolderHashReceipt(in: root)
    }

    func testGenerationlessVolumeHashesSameMetadataAutomatically() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-generationless-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(500),
            generationIdentifierProvider: { _ in nil },
            observesDirectoryChanges: false
        )
        let file = folder.appending(path: "batch.ndjson")
        let first = sample(id: "alpha", hour: 10)
        let changed = sample(id: "bravo", hour: 10)
        XCTAssertEqual(first.count, changed.count)
        try first.write(to: file)
        try settle(file)
        let preservedMetadata = try file.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let preservedDate = try XCTUnwrap(
            preservedMetadata.contentModificationDate
        )

        await watcher.start(folder: folder)
        _ = try await waitForIDs(["alpha"], in: store)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: preservedDate],
            ofItemAtPath: file.path
        )
        let changedMetadata = try file.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        XCTAssertEqual(changedMetadata.fileSize, preservedMetadata.fileSize)
        XCTAssertEqual(
            changedMetadata.contentModificationDate,
            preservedMetadata.contentModificationDate
        )
        XCTAssertEqual(
            changedMetadata.fileResourceIdentifier as? Data,
            preservedMetadata.fileResourceIdentifier as? Data
        )

        let ids = try await waitForIDs(["alpha", "bravo"], in: store)
        XCTAssertEqual(ids, ["alpha", "bravo"])
        await watcher.stop()
        await store.close()
    }

    func testGenerationlessAuditIsBoundedAndEventuallyFindsHiddenRewrite() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-rotating-audit-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let recorder = AuditRecorder()
        let fixture = sample(id: "sample-00", hour: 10)
        let perFileReadBytes = UInt64(fixture.count) * 2
        let byteBudget = perFileReadBytes * 2
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100),
            generationIdentifierProvider: { _ in nil },
            observesDirectoryChanges: false,
            generationlessAuditFileLimit: 2,
            generationlessAuditReadByteLimit: byteBudget,
            didCompleteGenerationlessAudit: { files, bytes in
                await recorder.record(files: files, bytes: bytes)
            }
        )
        var expected = Set<String>()
        for index in 0..<12 {
            let id = String(format: "sample-%02d", index)
            expected.insert(id)
            let file = folder.appending(
                path: String(format: "%02d.ndjson", index)
            )
            try sample(id: id, hour: 10).write(to: file)
            try settle(file)
        }

        await watcher.start(folder: folder)
        let initial = try await waitForIDs(expected, in: store)
        XCTAssertEqual(initial, expected)
        await recorder.reset()

        let hidden = folder.appending(path: "09.ndjson")
        let preservedMetadata = try hidden.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let changed = sample(id: "hidden-09", hour: 10)
        XCTAssertEqual(changed.count, fixture.count)
        let handle = try FileHandle(forWritingTo: hidden)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [
                .modificationDate: try XCTUnwrap(
                    preservedMetadata.contentModificationDate
                )
            ],
            ofItemAtPath: hidden.path
        )
        let changedMetadata = try hidden.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        XCTAssertEqual(changedMetadata.fileSize, preservedMetadata.fileSize)
        XCTAssertEqual(
            changedMetadata.contentModificationDate,
            preservedMetadata.contentModificationDate
        )
        XCTAssertEqual(
            changedMetadata.fileResourceIdentifier as? Data,
            preservedMetadata.fileResourceIdentifier as? Data
        )

        expected.insert("hidden-09")
        let discovered = try await waitForIDs(expected, in: store)
        XCTAssertEqual(discovered, expected)
        try await Task.sleep(for: .milliseconds(200))
        let cycles = await recorder.recordedCycles()
        XCTAssertFalse(cycles.isEmpty)
        XCTAssertTrue(
            cycles.allSatisfy { $0.files <= 2 },
            "Every audit cycle must respect the file bound: \(cycles)"
        )
        XCTAssertTrue(
            cycles.allSatisfy { $0.bytes <= byteBudget },
            "Every audit cycle must respect the read bound: \(cycles)"
        )
        await watcher.stop()
        await store.close()
    }

    func testLargeGenerationlessAuditNeverExceedsHardReadBudget() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-large-audit-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let recorder = AuditRecorder()
        let byteBudget: UInt64 = 16 * 1_024 * 1_024
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .seconds(1),
            generationIdentifierProvider: { _ in nil },
            observesDirectoryChanges: false,
            generationlessAuditFileLimit: 8,
            generationlessAuditReadByteLimit: byteBudget,
            didCompleteGenerationlessAudit: { files, bytes in
                await recorder.record(files: files, bytes: bytes)
            }
        )
        let targetSize = Int(9.4 * 1_024 * 1_024)
        var payload = sample(id: "large", hour: 10)
        payload.append(
            Data(repeating: 0x20, count: targetSize - payload.count)
        )
        XCTAssertEqual(payload.count, targetSize)
        XCTAssertGreaterThan(UInt64(payload.count) * 2, byteBudget)
        let file = folder.appending(path: "large.ndjson")
        try payload.write(to: file)
        try settle(file)

        await watcher.start(folder: folder)
        _ = try await waitForIDs(["large"], in: store)
        await recorder.reset()

        var cycles: [(files: Int, bytes: UInt64)] = []
        for _ in 0..<40 {
            cycles = await recorder.recordedCycles()
            if cycles.reduce(0, { $0 + $1.bytes }) >= UInt64(targetSize) * 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(
            cycles.reduce(0, { $0 + $1.bytes }),
            UInt64(targetSize) * 2
        )
        XCTAssertTrue(
            cycles.allSatisfy { $0.bytes <= byteBudget },
            "No audit may bypass the hard read limit: \(cycles)"
        )
        await watcher.stop()
        await store.close()
    }

    func testSuccessfulFileReplacedByLargeMalformedUsesBoundedFailureAudit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-large-failure-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let recorder = AuditRecorder()
        let rejected = EventCounter()
        let byteBudget: UInt64 = 16 * 1_024 * 1_024
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(250),
            generationIdentifierProvider: { _ in nil },
            observesDirectoryChanges: false,
            generationlessAuditReadByteLimit: byteBudget,
            didCompleteGenerationlessAudit: { files, bytes in
                await recorder.record(files: files, bytes: bytes)
            }
        )
        await watcher.onEvent { event in
            if case .rejected = event.outcome {
                Task { await rejected.increment() }
            }
        }
        let file = folder.appending(path: "batch.ndjson")
        try sample(id: "stored", hour: 10).write(to: file)
        try settle(file)
        await watcher.start(folder: folder)
        _ = try await waitForIDs(["stored"], in: store)
        await recorder.reset()

        let targetSize = Int(9.4 * 1_024 * 1_024)
        var malformed = Data("[".utf8)
        malformed.append(
            Data(repeating: 0x20, count: targetSize - malformed.count)
        )
        try malformed.write(to: file, options: .atomic)
        try settle(file)

        for _ in 0..<50 {
            if await rejected.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        var rejectionCount = await rejected.count
        XCTAssertEqual(rejectionCount, 1)

        var cycles: [(files: Int, bytes: UInt64)] = []
        for _ in 0..<60 {
            cycles = await recorder.recordedCycles()
            if cycles.reduce(0, { $0 + $1.bytes }) >= UInt64(targetSize) * 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let auditedBytes = cycles.reduce(0, { $0 + $1.bytes })
        XCTAssertGreaterThanOrEqual(auditedBytes, UInt64(targetSize) * 2)
        XCTAssertTrue(cycles.contains { $0.bytes > 0 })
        XCTAssertTrue(
            cycles.allSatisfy { $0.bytes <= byteBudget },
            "Failed-file audits must stay bounded: \(cycles)"
        )
        try await Task.sleep(for: .milliseconds(500))
        rejectionCount = await rejected.count
        XCTAssertEqual(rejectionCount, 1)
        await watcher.stop()
        await store.close()
    }

    func testIgnoredDirectoryEventBurstDoesNotTriggerGenerationlessAudits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-event-burst-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let recorder = AuditRecorder()
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .seconds(5),
            generationIdentifierProvider: { _ in nil },
            observesDirectoryChanges: false,
            didCompleteGenerationlessAudit: { files, bytes in
                await recorder.record(files: files, bytes: bytes)
            }
        )
        let first = folder.appending(path: "first.ndjson")
        try sample(id: "first", hour: 10).write(to: first)
        try settle(first)
        await watcher.start(folder: folder)
        _ = try await waitForIDs(["first"], in: store)
        await recorder.reset()

        for _ in 0..<100 {
            await watcher.directoryDidChange()
        }
        try await Task.sleep(for: .milliseconds(200))
        var auditCycles = await recorder.recordedCycles()
        XCTAssertTrue(auditCycles.isEmpty)

        let second = folder.appending(path: "second.ndjson")
        try sample(id: "second", hour: 11).write(to: second)
        try settle(second)
        await watcher.directoryDidChange()
        let ids = try await waitForIDs(["first", "second"], in: store)
        XCTAssertEqual(ids, ["first", "second"])
        auditCycles = await recorder.recordedCycles()
        XCTAssertTrue(auditCycles.isEmpty)
        await watcher.stop()
        await store.close()
    }

    func testPeriodicMetadataPassUsesABoundedPageWhileEventsStayImmediate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-metadata-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let fileSystem = FakeFileSystem()
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .seconds(60),
            observesDirectoryChanges: false,
            metadataPageLimit: 7,
            fileSystem: fileSystem
        )

        await watcher.start(folder: root.appending(path: "virtual-incoming"))
        fileSystem.resetCounts()
        let historical = (0..<10_000).map {
            String(format: "%05d.ndjson", $0)
        }
        fileSystem.replaceNames(historical)

        await watcher.runPeriodicReconciliationForTesting()

        var counts = fileSystem.counts()
        XCTAssertEqual(counts.fullListings, 0)
        XCTAssertEqual(counts.pageRequests, 1)
        XCTAssertLessThanOrEqual(counts.metadataNames.count, 7)
        let periodicCount = try await store.totalRecordCount()
        XCTAssertEqual(periodicCount, 7)

        let immediate = "immediate.ndjson"
        fileSystem.replaceNames(Array(historical.prefix(7)) + [immediate])
        fileSystem.resetCounts()
        await watcher.directoryDidChange()

        counts = fileSystem.counts()
        XCTAssertEqual(counts.fullListings, 1)
        let samples = try await store.samples(type: "steps")
        XCTAssertTrue(samples.contains { $0.id == immediate })
        await watcher.stop()
        await store.close()
    }

    func testPagedGenerationlessAuditEventuallyVisitsEntriesBeyondTheFirstSlice()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-paged-audit-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        let recorder = AuditRecorder()
        let fileSystem = FakeFileSystem()
        let names = (0..<80).map { String(format: "%02d.ndjson", $0) }
        fileSystem.replaceNames(names)
        fileSystem.setContentGenerationAvailable(false)
        for name in names {
            try fileSystem.data(for: name).write(
                to: folder.appending(path: name)
            )
        }
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .seconds(60),
            observesDirectoryChanges: false,
            metadataPageLimit: 64,
            generationlessAuditFileLimit: 8,
            didCompleteGenerationlessAudit: { files, bytes in
                await recorder.record(files: files, bytes: bytes)
            },
            fileSystem: fileSystem
        )

        await watcher.start(folder: folder)
        let initialCount = try await store.totalRecordCount()
        XCTAssertEqual(initialCount, 80)
        await recorder.reset()

        let rewrittenIDs = Set((8..<64).map { String(format: "hidden-%02d", $0) })
        for index in 8..<64 {
            let name = String(format: "%02d.ndjson", index)
            let replacement = Data(
                String(decoding: fileSystem.data(for: name), as: UTF8.self)
                    .replacingOccurrences(
                        of: name,
                        with: String(format: "hidden-%02d", index)
                    )
                    .utf8
            )
            XCTAssertEqual(replacement.count, fileSystem.data(for: name).count)
            fileSystem.replacePayload(replacement, for: name)
            try replacement.write(to: folder.appending(path: name))
        }

        for _ in 0..<16 {
            await watcher.runPeriodicReconciliationForTesting()
        }

        let samples = try await store.samples(type: "steps")
        let sampleIDs = Set(samples.map(\.id))
        XCTAssertTrue(
            rewrittenIDs.isSubset(of: sampleIDs),
            "Entries 8 through 63 in a 64-name page must all eventually be audited."
        )
        let cycles = await recorder.recordedCycles()
        XCTAssertEqual(cycles.count, 16)
        XCTAssertTrue(
            cycles.allSatisfy { $0.files <= 8 },
            "Page-local progress must not relax the per-cycle file bound: \(cycles)"
        )
        XCTAssertTrue(
            cycles.allSatisfy { $0.bytes <= 16 * 1_024 * 1_024 },
            "Page-local progress must not relax the per-cycle byte bound: \(cycles)"
        )
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameEqualClockFactsPreserveExistingAndInsertNew() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-facts-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        _ = try await store.ingest(
            try BatchParser.parse(sample(id: "receipt-source", hour: 10)),
            idempotencyKey: "facts.ndjson"
        )
        let newerFacts = Data(
            """
            {"kind":"characteristics","schemaVersion":1,"readAt":"2026-03-02T00:00:00.008Z","characteristics":{"HKCharacteristicTypeIdentifierBloodType":{"state":"known","value":"APositive"}}}
            {"kind":"typeCoverage","type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-03-02T00:00:00.008Z"}
            """.utf8
        )
        _ = try await store.ingest(
            try BatchParser.parse(newerFacts),
            idempotencyKey: "newer-facts"
        )
        let changedFile = Data(
            """
            {"kind":"characteristics","schemaVersion":1,"readAt":"2026-03-02T00:00:00.008Z","characteristics":{"HKCharacteristicTypeIdentifierBloodType":{"state":"known","value":"BNegative"},"HKCharacteristicTypeIdentifierBiologicalSex":{"state":"known","value":"Female"}}}
            {"kind":"typeCoverage","type":"steps","state":"draining","complete":false,"observedAt":"2026-03-02T00:00:00.008Z"}
            {"kind":"typeCoverage","type":"heart-rate","state":"anchorClosed","complete":true,"observedAt":"2026-03-02T00:00:00.008Z"}
            """.utf8
        )
        let file = folder.appending(path: "facts.ndjson")
        try changedFile.write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let characteristics = try await store.characteristics()
        XCTAssertEqual(
            characteristics.first {
                $0.type == "HKCharacteristicTypeIdentifierBloodType"
            }?.value,
            "APositive"
        )
        XCTAssertEqual(
            characteristics.first {
                $0.type == "HKCharacteristicTypeIdentifierBiologicalSex"
            }?.value,
            "Female"
        )
        let coverage = try await store.coverage()
        XCTAssertEqual(coverage["steps"]?.state.rawValue, "anchorClosed")
        XCTAssertEqual(coverage["heart-rate"]?.state.rawValue, "anchorClosed")
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameCharacteristicAt009Supersedes008() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-characteristic-clock-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        _ = try await store.ingest(
            try BatchParser.parse(sample(id: "receipt-source", hour: 10)),
            idempotencyKey: "characteristic.ndjson"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    #"{"kind":"characteristics","schemaVersion":1,"readAt":"2026-03-02T00:00:00.008Z","characteristics":{"HKCharacteristicTypeIdentifierBloodType":{"state":"known","value":"APositive"}}}"#
                        .utf8
                )
            ),
            idempotencyKey: "characteristic-008"
        )
        let file = folder.appending(path: "characteristic.ndjson")
        try Data(
            #"{"kind":"characteristics","schemaVersion":1,"readAt":"2026-03-02T00:00:00.009Z","characteristics":{"HKCharacteristicTypeIdentifierBloodType":{"state":"known","value":"BNegative"}}}"#
                .utf8
        ).write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)

        let characteristics = try await store.characteristics()
        let blood = characteristics.first {
            $0.type == "HKCharacteristicTypeIdentifierBloodType"
        }
        XCTAssertEqual(blood?.value, "BNegative")
        let readAt = try XCTUnwrap(blood?.readAt)
        XCTAssertEqual(
            Int64((readAt.timeIntervalSince1970 * 1_000).rounded()),
            1_772_409_600_009
        )
        await watcher.stop()
        await store.close()
    }

    func testLegacyFilenameCoverageAt009Supersedes008() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-folder-coverage-clock-\(UUID().uuidString)")
        let folder = root.appending(path: "incoming")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IngestStore(directory: root.appending(path: "store"))
        _ = try await store.ingest(
            try BatchParser.parse(sample(id: "receipt-source", hour: 10)),
            idempotencyKey: "coverage.ndjson"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    #"{"kind":"typeCoverage","type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-03-02T00:00:00.008Z"}"#
                        .utf8
                )
            ),
            idempotencyKey: "coverage-008"
        )
        let file = folder.appending(path: "coverage.ndjson")
        try Data(
            #"{"kind":"typeCoverage","type":"steps","state":"draining","complete":false,"observedAt":"2026-03-02T00:00:00.009Z"}"#
                .utf8
        ).write(to: file)
        try settle(file)
        let watcher = FolderIngestWatcher(
            store: store,
            reconciliationInterval: .milliseconds(100)
        )

        await watcher.start(folder: folder)
        let coverage = try await store.coverage()
        XCTAssertEqual(coverage["steps"]?.state.rawValue, "draining")
        XCTAssertEqual(coverage["steps"]?.state.rawValue, "draining")
        let observedAt = try XCTUnwrap(coverage["steps"]?.observedAt)
        XCTAssertEqual(
            Int64((observedAt.timeIntervalSince1970 * 1_000).rounded()),
            1_772_409_600_009
        )
        await watcher.stop()
        await store.close()
    }

    private func settle(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-2)],
            ofItemAtPath: file.path
        )
    }

    private func assertOneFolderHashReceipt(in root: URL) throws {
        let database = try SQLiteDatabase(
            url: root.appending(path: "store/hozz-received.sqlite")
        )
        defer { database.close() }
        let receipts = try database.query(
            """
            SELECT COUNT(*) FROM batch
            WHERE key LIKE 'folder-v2:%' AND receipt_version = 1
            """,
            row: { $0.integer(0) }
        ).first
        XCTAssertEqual(receipts, 1)
    }

    private func waitForCount(
        _ expected: Int,
        in store: IngestStore
    ) async throws -> Int {
        var count = 0
        for _ in 0..<50 {
            count = try await store.totalRecordCount()
            if count == expected {
                return count
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return count
    }

    private func waitForIDs(
        _ expected: Set<String>,
        in store: IngestStore
    ) async throws -> Set<String> {
        var ids: Set<String> = []
        for _ in 0..<50 {
            ids = Set(try await store.samples(type: "steps").map(\.id))
            if ids == expected {
                return ids
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ids
    }

    private func sample(id: String, hour: Int, value: Int? = nil) -> Data {
        Data(
            """
            {"id":"\(id)","type":"steps","kind":"quantity",\
            "startDate":"2026-01-01T\(hour):00:00.000Z",\
            "quantity":{"value":\(value ?? hour),"unit":"count"}}

            """.utf8
        )
    }
}
