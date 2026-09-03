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

    /// Reads every entry out of a Zip64 archive, verifying each checksum.
    ///
    /// This walks the central directory rather than trusting the writer, so a
    /// bad offset, size, or CRC fails the test instead of shipping.
    static func readZipEntries(at fileURL: URL) throws -> [String: Data] {
        let archive = try Data(contentsOf: fileURL)
        guard archive.count > 22 else {
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

        // Locate the Zip64 end-of-central-directory record.
        guard let locator = (0..<archive.count - 3).reversed().first(where: {
            u32($0) == 0x0706_4B50
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let zip64End = Int(u64(locator + 8))
        guard zip64End + 56 <= archive.count, u32(zip64End) == 0x0606_4B50 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let entryCount = Int(u64(zip64End + 32))
        var cursor = Int(u64(zip64End + 48))

        var results: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard u32(cursor) == 0x0201_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let storedCRC = u32(cursor + 16)
            let nameLength = Int(u16(cursor + 28))
            let extraLength = Int(u16(cursor + 30))
            let commentLength = Int(u16(cursor + 32))
            let name = String(
                decoding: archive.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)),
                as: UTF8.self
            )

            let extraOffset = cursor + 46 + nameLength
            guard extraLength >= 24, u16(extraOffset) == 0x0001 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let uncompressedSize = u64(extraOffset + 4)
            let compressedSize = u64(extraOffset + 12)
            let headerOffset = Int(u64(extraOffset + 20))

            // Re-derive the payload position from the local header, so a wrong
            // offset in either record is caught.
            guard u32(headerOffset) == 0x0403_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let localNameLength = Int(u16(headerOffset + 26))
            let localExtraLength = Int(u16(headerOffset + 28))
            let dataStart = headerOffset + 30 + localNameLength + localExtraLength
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

            results[name] = inflated
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return results
    }

    /// Reads the one entry a single-entry archive holds.
    static func readSingleZipEntry(at fileURL: URL) throws -> Data {
        let entries = try readZipEntries(at: fileURL)
        guard entries.count == 1, let only = entries.values.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return only
    }

    /// Parses an NDJSON export into one dictionary per line.
    static func records(in fileURL: URL) throws -> [[String: Any]] {
        let entries = try readZipEntries(at: fileURL)
        guard
            let records = entries
                .filter({ $0.key.hasSuffix(".ndjson") })
                .sorted(by: { $0.key < $1.key })
                .first?
                .value
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try lines(in: records)
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
