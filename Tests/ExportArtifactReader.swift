import Foundation
import XCTest
import zlib

/// Reads the artifacts an export produced, the way a user's tools would.
enum ExportArtifactReader {
    /// Inflates a raw deflate stream (no zlib or gzip wrapper).
    static func inflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var input = [UInt8](data)

        try input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)

            while true {
                var status: Int32 = Z_OK
                let produced: Int = buffer.withUnsafeMutableBytes { outputBytes in
                    stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBytes.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return outputBytes.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }
                if status == Z_STREAM_END {
                    break
                }
                if produced == 0, stream.avail_in == 0 {
                    break
                }
            }
        }
        return output
    }

    static func crc32(of data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(
                truncatingIfNeeded: zlib.crc32(
                    0,
                    bytes.bindMemory(to: Bytef.self).baseAddress,
                    uInt(data.count)
                )
            )
        }
    }

    /// Reads the single entry out of a Zip64 archive, verifying its CRC.
    ///
    /// This parses the archive rather than trusting the writer, so a malformed
    /// header or a bad checksum fails the test instead of shipping.
    static func readSingleZipEntry(at fileURL: URL) throws -> Data {
        let archive = try Data(contentsOf: fileURL)
        guard archive.count > 30 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(archive[offset]) | (UInt16(archive[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { partial, index in
                partial | (UInt32(archive[offset + index]) << (8 * UInt32(index)))
            }
        }
        func u64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { partial, index in
                partial | (UInt64(archive[offset + index]) << (8 * UInt64(index)))
            }
        }

        guard u32(0) == 0x0403_4B50 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard u16(8) == 8 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let storedCRC = u32(14)
        let nameLength = Int(u16(26))
        let extraLength = Int(u16(28))
        let extraOffset = 30 + nameLength

        guard extraLength >= 20, u16(extraOffset) == 0x0001 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let uncompressedSize = u64(extraOffset + 4)
        let compressedSize = u64(extraOffset + 12)

        let dataStart = extraOffset + extraLength
        let dataEnd = dataStart + Int(compressedSize)
        guard dataEnd <= archive.count else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let inflated = try inflateRaw(archive.subdata(in: dataStart..<dataEnd))
        guard UInt64(inflated.count) == uncompressedSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard crc32(of: inflated) == storedCRC else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return inflated
    }

    /// Parses an NDJSON export into one dictionary per line.
    static func records(in fileURL: URL) throws -> [[String: Any]] {
        try lines(in: try readSingleZipEntry(at: fileURL))
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
