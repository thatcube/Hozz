import Foundation
import XCTest
import zlib

/// Shared helpers for tests that read the artifacts an export produced.
enum ExportArtifactReader {
    /// Decompresses a gzip file, including one made of concatenated members.
    static func gunzip(_ fileURL: URL) throws -> Data {
        guard let file = gzopen(fileURL.path, "rb") else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { gzclose(file) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = gzread(file, &buffer, UInt32(buffer.count))
            guard count >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard count > 0 else {
                return result
            }
            result.append(buffer, count: Int(count))
        }
    }

    /// Parses an NDJSON export into one dictionary per line.
    static func records(in fileURL: URL) throws -> [[String: Any]] {
        let data = try gunzip(fileURL)
        return try lines(in: data)
    }

    static func lines(in data: Data) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                guard
                    let object = try JSONSerialization.jsonObject(
                        with: Data(line.utf8)
                    ) as? [String: Any]
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return object
            }
    }
}

/// A throwaway directory that is removed when the test finishes.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "HozzTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
