import Foundation
import XCTest
@testable import HozzHealth

/// The archive has to be readable by a stock Mac, so these tests parse the ZIP
/// structure and verify checksums rather than trusting the writer.
final class ZipStreamWriterTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    /// Writes a part exactly as the exporter does: raw deflate, ended with a
    /// sync flush so another part can follow it.
    private func makePart(_ lines: [String], named name: String) throws -> ZipMember {
        let url = directory.url.appending(path: name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try DeflateExportOutput(fileURL: url)
        var uncompressed = Data()
        for line in lines {
            let payload = Data((line + "\n").utf8)
            try output.write(payload)
            uncompressed.append(payload)
        }
        let summary = try output.finish()

        XCTAssertEqual(summary.uncompressedByteCount, UInt64(uncompressed.count))
        XCTAssertEqual(summary.crc32, ExportArtifactReader.crc32(of: uncompressed))
        return ZipMember(
            url: url,
            compressedByteCount: summary.compressedByteCount,
            uncompressedByteCount: summary.uncompressedByteCount,
            crc32: summary.crc32
        )
    }

    private func makeWriter() throws -> (ZipStreamWriter, URL) {
        let destination = directory.url.appending(path: "export.zip")
        let writer = try ZipStreamWriter(
            destinationURL: destination,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return (writer, destination)
    }

    // MARK: - Copied entries

    func testASinglePartEntryRoundTrips() throws {
        let member = try makePart(["alpha", "bravo"], named: "part-0.deflate")
        let (writer, destination) = try makeWriter()

        try writer.addEntry(name: "export.ndjson", copying: [member])
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            String(decoding: entries["export.ndjson"] ?? Data(), as: UTF8.self),
            "alpha\nbravo\n"
        )
    }

    /// The reason parts end with a sync flush rather than a final block.
    func testConcatenatedPartsFormOneValidStream() throws {
        let members = [
            try makePart(["alpha", "bravo"], named: "part-0.deflate"),
            try makePart(["charlie"], named: "part-1.deflate"),
            try makePart(["delta", "echo"], named: "part-2.deflate")
        ]
        let (writer, destination) = try makeWriter()

        try writer.addEntry(name: "export.ndjson", copying: members)
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        XCTAssertEqual(
            String(decoding: entries["export.ndjson"] ?? Data(), as: UTF8.self),
            "alpha\nbravo\ncharlie\ndelta\necho\n"
        )
    }

    func testManyPartsSurviveTheJoin() throws {
        let members = try (0..<40).map { index in
            try makePart(
                (0..<25).map { "record-\(index)-\($0)" },
                named: "part-\(index).deflate"
            )
        }
        let (writer, destination) = try makeWriter()

        try writer.addEntry(name: "export.ndjson", copying: members)
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        let lines = String(decoding: entries["export.ndjson"] ?? Data(), as: UTF8.self)
            .split(separator: "\n")

        XCTAssertEqual(lines.count, 1_000)
        XCTAssertEqual(lines.first, "record-0-0")
        XCTAssertEqual(lines.last, "record-39-24")
    }

    // MARK: - Streamed entries

    func testStreamedEntryRoundTrips() throws {
        let (writer, destination) = try makeWriter()

        try writer.beginEntry(name: "steps.csv")
        try writer.write(Data("id,value\n".utf8))
        for index in 0..<500 {
            try writer.write(Data("row-\(index),\(index)\n".utf8))
        }
        try writer.endEntry()
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        let text = String(decoding: entries["steps.csv"] ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n")

        XCTAssertEqual(lines.count, 501)
        XCTAssertEqual(lines.first, "id,value")
        XCTAssertEqual(lines.last, "row-499,499")
    }

    /// A CSV export writes one entry per data type, so several entries have to
    /// coexist with correct offsets in the central directory.
    func testManyEntriesAreAllReadable() throws {
        let (writer, destination) = try makeWriter()

        for index in 0..<25 {
            try writer.beginEntry(name: "type-\(index).csv")
            try writer.write(Data("id,value\n".utf8))
            for row in 0..<50 {
                try writer.write(Data("\(index)-\(row),\(row)\n".utf8))
            }
            try writer.endEntry()
        }
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        XCTAssertEqual(entries.count, 25)
        for index in 0..<25 {
            let text = String(
                decoding: entries["type-\(index).csv"] ?? Data(),
                as: UTF8.self
            )
            XCTAssertEqual(text.split(separator: "\n").count, 51)
            XCTAssertTrue(text.contains("\(index)-49,49"))
        }
    }

    func testCopiedAndStreamedEntriesCoexist() throws {
        let member = try makePart(["alpha"], named: "part-0.deflate")
        let (writer, destination) = try makeWriter()

        try writer.addEntry(name: "copied.ndjson", copying: [member])
        try writer.beginEntry(name: "streamed.csv")
        try writer.write(Data("hello\n".utf8))
        try writer.endEntry()
        _ = try writer.finish()

        let entries = try ExportArtifactReader.readZipEntries(at: destination)
        XCTAssertEqual(
            String(decoding: entries["copied.ndjson"] ?? Data(), as: UTF8.self),
            "alpha\n"
        )
        XCTAssertEqual(
            String(decoding: entries["streamed.csv"] ?? Data(), as: UTF8.self),
            "hello\n"
        )
    }

    // MARK: - Integrity

    func testCombinedChecksumMatchesTheWholeStream() throws {
        let first = try makePart(["alpha", "bravo"], named: "part-0.deflate")
        let second = try makePart(["charlie"], named: "part-1.deflate")

        let combined = ZipStreamWriter.combinedCRC(of: [first, second])
        let expected = ExportArtifactReader.crc32(
            of: Data("alpha\nbravo\ncharlie\n".utf8)
        )

        XCTAssertEqual(combined, expected)
    }

    func testCompressionActuallyShrinksRepetitiveData() throws {
        let member = try makePart(
            (0..<2_000).map { _ in #"{"kind":"quantity","value":12345}"# },
            named: "part-0.deflate"
        )

        XCTAssertLessThan(
            member.compressedByteCount,
            member.uncompressedByteCount / 10
        )
    }

    func testAMissingPartFailsBeforeTheArchiveIsPublished() throws {
        let (writer, destination) = try makeWriter()
        let missing = ZipMember(
            url: directory.url.appending(path: "gone.deflate"),
            compressedByteCount: 10,
            uncompressedByteCount: 10,
            crc32: 0
        )

        XCTAssertThrowsError(
            try writer.addEntry(name: "export.ndjson", copying: [missing])
        )
        writer.abandon()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAbandoningLeavesNoScratchFile() throws {
        let (writer, destination) = try makeWriter()
        try writer.beginEntry(name: "partial.csv")
        try writer.write(Data("abandoned\n".utf8))

        writer.abandon()

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("zipping-") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNoScratchFileSurvivesASuccessfulWrite() throws {
        let member = try makePart(["alpha"], named: "part-0.deflate")
        let (writer, _) = try makeWriter()

        try writer.addEntry(name: "export.ndjson", copying: [member])
        _ = try writer.finish()

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("zipping-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
