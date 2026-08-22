import Foundation
import HozzStore
import zlib

enum ExportPartInflaterError: Error, LocalizedError {
    case corruptPart(String)

    var errorDescription: String? {
        switch self {
        case .corruptPart(let name):
            "Hozz could not read the export part \(name)."
        }
    }
}

/// Expands a run's compressed parts back into plain NDJSON.
///
/// Only the formats that have to inspect every record use this. NDJSON exports
/// copy their compressed parts straight into the archive and never come here.
enum ExportPartInflater {
    private static let bufferSize = 1 * 1_024 * 1_024

    static func inflate(partURLs: [URL], into destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.protectionKey: StoreLocation.protection]
        ) else {
            throw ExportPartInflaterError.corruptPart(
                destinationURL.lastPathComponent
            )
        }
        try? StoreLocation.harden(destinationURL)

        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        // Each part is a raw deflate stream that was ended with a sync flush,
        // so each one is inflated on its own and the results appended.
        for url in partURLs {
            try inflateOne(url: url, into: output)
        }
        try output.synchronize()
    }

    private static func inflateOne(url: URL, into output: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ExportPartInflaterError.corruptPart(url.lastPathComponent)
        }
        defer { inflateEnd(&stream) }

        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            var chunk = try reader.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty {
                break
            }

            try chunk.withUnsafeMutableBytes { inputBytes in
                stream.next_in = inputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inputBytes.count)

                repeat {
                    var status = Z_OK
                    let produced: Int = try outputBuffer.withUnsafeMutableBytes { out in
                        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(out.count)
                        status = zlib.inflate(&stream, Z_NO_FLUSH)
                        guard
                            status == Z_OK
                                || status == Z_STREAM_END
                                || status == Z_BUF_ERROR
                        else {
                            throw ExportPartInflaterError.corruptPart(
                                url.lastPathComponent
                            )
                        }
                        return out.count - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        try output.write(contentsOf: Data(outputBuffer.prefix(produced)))
                    }
                    if status == Z_STREAM_END || produced == 0 {
                        break
                    }
                } while stream.avail_in > 0
            }
        }
    }
}
