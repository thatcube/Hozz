import Foundation
import XCTest
@testable import HozzHealth

/// The archive has to be readable by a stock Mac, so these tests parse the ZIP
/// structure and verify the checksum rather than trusting the writer.
final class ZipArchiveWriterTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    /// Writes one part exactly as the exporter does: raw deflate, ended with a
    /// sync flush so it can be followed by another part.
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

    private func write(_ members: [ZipMember]) throws -> URL {
        let destination = directory.url.appending(path: "export.zip")
        _ = try ZipArchiveWriter.write(
            members: members,
            entryName: "export.ndjson",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            to: destination
        )
        return destination
    }

    func testASinglePartArchiveRoundTrips() throws {
        let member = try makePart(["alpha", "bravo"], named: "part-0.deflate")

        let archive = try write([member])
        let entry = try ExportArtifactReader.readSingleZipEntry(at: archive)

        XCTAssertEqual(String(decoding: entry, as: UTF8.self), "alpha\nbravo\n")
    }

    /// The whole point of ending parts with a sync flush instead of a final
    /// block: several parts concatenate into one valid deflate stream.
    func testConcatenatedPartsFormOneValidStream() throws {
        let members = [
            try makePart(["alpha", "bravo"], named: "part-0.deflate"),
            try makePart(["charlie"], named: "part-1.deflate"),
            try makePart(["delta", "echo"], named: "part-2.deflate")
        ]

        let archive = try write(members)
        let entry = try ExportArtifactReader.readSingleZipEntry(at: archive)

        XCTAssertEqual(
            String(decoding: entry, as: UTF8.self),
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

        let archive = try write(members)
        let entry = try ExportArtifactReader.readSingleZipEntry(at: archive)
        let lines = String(decoding: entry, as: UTF8.self)
            .split(separator: "\n")

        XCTAssertEqual(lines.count, 1_000)
        XCTAssertEqual(lines.first, "record-0-0")
        XCTAssertEqual(lines.last, "record-39-24")
    }

    /// A part boundary must not corrupt data that compresses well, which is
    /// where a mishandled deflate history window would show up.
    func testHighlyCompressibleDataSurvivesPartBoundaries() throws {
        let repeated = String(repeating: "the same line over and over", count: 1)
        let members = try (0..<8).map { index in
            try makePart(
                (0..<200).map { _ in repeated },
                named: "part-\(index).deflate"
            )
        }

        let archive = try write(members)
        let entry = try ExportArtifactReader.readSingleZipEntry(at: archive)
        let lines = String(decoding: entry, as: UTF8.self).split(separator: "\n")

        XCTAssertEqual(lines.count, 1_600)
        XCTAssertTrue(lines.allSatisfy { $0 == repeated })
    }

    func testCombinedChecksumMatchesTheWholeStream() throws {
        let first = try makePart(["alpha", "bravo"], named: "part-0.deflate")
        let second = try makePart(["charlie"], named: "part-1.deflate")

        let combined = ZipArchiveWriter.combinedCRC(of: [first, second])
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
            member.uncompressedByteCount / 10,
            "The export must stay meaningfully compressed."
        )
    }

    func testAMissingPartFailsBeforeTheArchiveIsPublished() throws {
        let member = try makePart(["alpha"], named: "part-0.deflate")
        let missing = ZipMember(
            url: directory.url.appending(path: "gone.deflate"),
            compressedByteCount: 10,
            uncompressedByteCount: 10,
            crc32: 0
        )
        let destination = directory.url.appending(path: "export.zip")

        XCTAssertThrowsError(
            try ZipArchiveWriter.write(
                members: [member, missing],
                entryName: "export.ndjson",
                modifiedAt: .now,
                to: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNoScratchFileSurvivesASuccessfulWrite() throws {
        let members = [
            try makePart(["alpha"], named: "part-0.deflate"),
            try makePart(["bravo"], named: "part-1.deflate")
        ]

        _ = try write(members)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("zipping-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
