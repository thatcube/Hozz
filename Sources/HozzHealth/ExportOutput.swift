import Foundation
import zlib

enum ExportOutputError: Error {
    case compressionInitialization(Int32)
    case compressionFailed(Int32)
}

/// What a finished part contributed, which is everything the archive writer
/// needs to describe it without re-reading the bytes.
struct ExportOutputSummary: Equatable, Sendable {
    let compressedByteCount: UInt64
    let uncompressedByteCount: UInt64
    let crc32: UInt32
}

protocol ExportOutput: AnyObject {
    func write(_ data: Data) throws
    func synchronize() throws
    func finish() throws -> ExportOutputSummary
    func abandon()
}

/// Plain, uncompressed output for the advanced `.ndjson` format.
final class RawExportOutput: ExportOutput {
    private let handle: FileHandle
    private var isClosed = false
    private var uncompressedByteCount: UInt64 = 0
    private var crc: uLong = 0

    init(fileURL: URL) throws {
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        uncompressedByteCount += UInt64(data.count)
        crc = Self.updateCRC(crc, with: data)
    }

    func synchronize() throws {
        try handle.synchronize()
    }

    func finish() throws -> ExportOutputSummary {
        guard !isClosed else {
            return ExportOutputSummary(
                compressedByteCount: 0,
                uncompressedByteCount: 0,
                crc32: 0
            )
        }
        try synchronize()
        let byteCount = try handle.offset()
        try handle.close()
        isClosed = true
        return ExportOutputSummary(
            compressedByteCount: byteCount,
            uncompressedByteCount: uncompressedByteCount,
            crc32: UInt32(truncatingIfNeeded: crc)
        )
    }

    func abandon() {
        guard !isClosed else {
            return
        }
        try? handle.close()
        isClosed = true
    }

    static func updateCRC(_ crc: uLong, with data: Data) -> uLong {
        guard !data.isEmpty else {
            return crc
        }
        return data.withUnsafeBytes { bytes in
            zlib.crc32(
                crc,
                bytes.bindMemory(to: Bytef.self).baseAddress,
                uInt(data.count)
            )
        }
    }

    deinit {
        abandon()
    }
}

/// A raw deflate stream that can be concatenated with others.
///
/// The stream is finished with `Z_SYNC_FLUSH` rather than `Z_FINISH`, so it
/// ends byte-aligned and *without* a final block. Several such streams placed
/// end to end form one valid deflate stream once a terminating block is
/// appended, which is what lets an interrupted export be stitched back together
/// with no recompression.
///
/// Each part starts with an empty history window, so a back-reference can only
/// point inside its own part. That costs a little compression at each boundary
/// and buys the ability to resume.
final class DeflateExportOutput: ExportOutput {
    private static let bufferSize = 64 * 1_024

    private let handle: FileHandle
    private var stream = z_stream()
    private var isActive = false
    private var isClosed = false
    private var needsFlush = false
    private var failure: (any Error)?
    private var uncompressedByteCount: UInt64 = 0
    private var crc: uLong = 0

    init(fileURL: URL) throws {
        handle = try FileHandle(forWritingTo: fileURL)
        // A negative window size selects raw deflate: no zlib or gzip wrapper,
        // which is exactly what a ZIP entry stores.
        let status = deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            try? handle.close()
            throw ExportOutputError.compressionInitialization(status)
        }
        isActive = true
    }

    func write(_ data: Data) throws {
        if let failure {
            throw failure
        }
        guard !data.isEmpty else {
            return
        }
        needsFlush = true
        do {
            try data.withUnsafeBytes { inputBytes in
                guard let input = inputBytes.bindMemory(to: Bytef.self).baseAddress else {
                    return
                }
                stream.next_in = UnsafeMutablePointer(mutating: input)
                stream.avail_in = uInt(data.count)
                defer {
                    stream.next_in = nil
                    stream.avail_in = 0
                }

                while stream.avail_in > 0 {
                    _ = try drain(flush: Z_NO_FLUSH)
                }
            }
        } catch {
            failure = error
            throw error
        }
        uncompressedByteCount += UInt64(data.count)
        crc = RawExportOutput.updateCRC(crc, with: data)
    }

    func synchronize() throws {
        if let failure {
            throw failure
        }
        do {
            if needsFlush {
                _ = try drain(flush: Z_SYNC_FLUSH)
                needsFlush = false
            }
            try handle.synchronize()
        } catch {
            failure = error
            throw error
        }
    }

    func finish() throws -> ExportOutputSummary {
        guard !isClosed else {
            return ExportOutputSummary(
                compressedByteCount: 0,
                uncompressedByteCount: 0,
                crc32: 0
            )
        }
        if let failure {
            throw failure
        }

        // Deliberately not Z_FINISH: a final block here would stop a decoder
        // from reading the parts that follow.
        _ = try drain(flush: Z_SYNC_FLUSH)
        needsFlush = false
        endCompression()

        try handle.synchronize()
        let byteCount = try handle.offset()
        try handle.close()
        isClosed = true
        return ExportOutputSummary(
            compressedByteCount: byteCount,
            uncompressedByteCount: uncompressedByteCount,
            crc32: UInt32(truncatingIfNeeded: crc)
        )
    }

    func abandon() {
        guard !isClosed else {
            return
        }
        endCompression()
        try? handle.close()
        isClosed = true
    }

    private func drain(flush: Int32) throws -> Int32 {
        var output = [UInt8](repeating: 0, count: Self.bufferSize)
        var status = Z_OK

        repeat {
            let produced: Int = try output.withUnsafeMutableBytes { outputBytes in
                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBytes.count)
                status = deflate(&stream, flush)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw ExportOutputError.compressionFailed(status)
                }
                return outputBytes.count - Int(stream.avail_out)
            }

            if produced > 0 {
                try handle.write(contentsOf: Data(output.prefix(produced)))
            }
        } while stream.avail_in > 0 || (flush != Z_NO_FLUSH && stream.avail_out == 0)

        return status
    }

    private func endCompression() {
        guard isActive else {
            return
        }
        deflateEnd(&stream)
        isActive = false
    }

    deinit {
        abandon()
    }
}
