import Foundation
@testable import HozzReceive
import XCTest

final class FolderIngestWatcherTests: XCTestCase {
    private actor EventCounter {
        private(set) var count = 0

        func increment() {
            count += 1
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
        let watcher = FolderIngestWatcher(store: store)
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
        let watcher = FolderIngestWatcher(store: store)
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

    private func settle(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-2)],
            ofItemAtPath: file.path
        )
    }
}
