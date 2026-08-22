import Foundation
import XCTest
@testable import HozzHealth

final class ExportPartJoinerTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeGzipPart(_ lines: [String], named name: String) throws -> URL {
        let url = directory.url.appending(path: name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try GzipExportOutput(fileURL: url)
        for line in lines {
            try output.write(Data(line.utf8))
            try output.write(Data([0x0A]))
        }
        _ = try output.finish()
        return url
    }

    func testConcatenatedGzipMembersDecompressAsOneStream() throws {
        let first = try makeGzipPart(["a", "b"], named: "part-0.ndjson.gz")
        let second = try makeGzipPart(["c"], named: "part-1.ndjson.gz")
        let third = try makeGzipPart(["d", "e"], named: "part-2.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        let byteCount = try ExportPartJoiner.join(
            sourceURLs: [first, second, third],
            into: destination
        )
        let text = String(
            decoding: try ExportArtifactReader.gunzip(destination),
            as: UTF8.self
        )

        XCTAssertEqual(text, "a\nb\nc\nd\ne\n")
        XCTAssertGreaterThan(byteCount, 0)
    }

    func testJoiningLeavesItsSourcesInPlace() throws {
        let first = try makeGzipPart(["a"], named: "part-0.ndjson.gz")
        let second = try makeGzipPart(["b"], named: "part-1.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        _ = try ExportPartJoiner.join(sourceURLs: [first, second], into: destination)

        // Deleting sources here would open a crash window where the joined file
        // exists but the store does not know it yet, and a retry would find its
        // inputs gone. The caller removes them once the store has caught up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testJoiningIsIdempotentWhenRepeatedFromTheSameSources() throws {
        let first = try makeGzipPart(["a"], named: "part-0.ndjson.gz")
        let second = try makeGzipPart(["b"], named: "part-1.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        _ = try ExportPartJoiner.join(sourceURLs: [first, second], into: destination)
        _ = try ExportPartJoiner.join(sourceURLs: [first, second], into: destination)

        XCTAssertEqual(
            String(decoding: try ExportArtifactReader.gunzip(destination), as: UTF8.self),
            "a\nb\n"
        )
    }

    func testASinglePartIsMovedRatherThanCopied() throws {
        let only = try makeGzipPart(["a"], named: "part-0.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        _ = try ExportPartJoiner.join(sourceURLs: [only], into: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: only.path))
        XCTAssertEqual(
            String(decoding: try ExportArtifactReader.gunzip(destination), as: UTF8.self),
            "a\n"
        )
    }

    func testAMissingPartFailsBeforeAnythingIsMoved() throws {
        let first = try makeGzipPart(["a"], named: "part-0.ndjson.gz")
        let missing = directory.url.appending(path: "part-1.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        XCTAssertThrowsError(
            try ExportPartJoiner.join(sourceURLs: [first, missing], into: destination)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A join that produced the destination but failed before the store caught
    /// up is retried with the destination as its own first member.
    func testTheDestinationCanBeItsOwnFirstSource() throws {
        let destination = directory.url.appending(path: "final.ndjson.gz")
        let alreadyJoined = try makeGzipPart(["a", "b"], named: "final.ndjson.gz")
        XCTAssertEqual(alreadyJoined, destination)
        let late = try makeGzipPart(["c"], named: "part-9.ndjson.gz")

        _ = try ExportPartJoiner.join(
            sourceURLs: [destination, late],
            into: destination
        )

        XCTAssertEqual(
            String(decoding: try ExportArtifactReader.gunzip(destination), as: UTF8.self),
            "a\nb\nc\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: late.path),
            "Sources are removed by the caller, not the joiner."
        )
    }

    func testRejoiningOnlyTheDestinationIsANoOp() throws {
        let destination = directory.url.appending(path: "final.ndjson.gz")
        _ = try makeGzipPart(["a"], named: "final.ndjson.gz")

        let byteCount = try ExportPartJoiner.join(
            sourceURLs: [destination],
            into: destination
        )

        XCTAssertGreaterThan(byteCount, 0)
        XCTAssertEqual(
            String(decoding: try ExportArtifactReader.gunzip(destination), as: UTF8.self),
            "a\n"
        )
    }

    func testAnInterruptedJoinLeavesNoScratchFileBehind() throws {
        let first = try makeGzipPart(["a"], named: "part-0.ndjson.gz")
        let second = try makeGzipPart(["b"], named: "part-1.ndjson.gz")
        let destination = directory.url.appending(path: "final.ndjson.gz")

        _ = try ExportPartJoiner.join(sourceURLs: [first, second], into: destination)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(ExportPartJoiner.scratchPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
