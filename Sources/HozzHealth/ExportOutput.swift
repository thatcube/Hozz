import Foundation
import zlib

enum ExportOutputError: Error {
    case compressionInitialization(Int32)
    case compressionFailed(Int32)
}

protocol ExportOutput: AnyObject {
    func write(_ data: Data) throws
    func synchronize() throws
    func finish() throws -> UInt64
    func abandon()
}

final class RawExportOutput: ExportOutput {
    private let handle: FileHandle
    private var isClosed = false

    init(fileURL: URL) throws {
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func synchronize() throws {
        try handle.synchronize()
    }

    func finish() throws -> UInt64 {
        guard !isClosed else {
            return 0
        }
        try synchronize()
        let byteCount = try handle.offset()
        try handle.close()
        isClosed = true
        return byteCount
    }

    func abandon() {
        guard !isClosed else {
            return
        }
        try? handle.close()
        isClosed = true
    }

    deinit {
        abandon()
    }
}

final class GzipExportOutput: ExportOutput {
    private static let bufferSize = 64 * 1_024

    private let handle: FileHandle
    private var stream = z_stream()
    private var isActive = false
    private var isClosed = false
    private var needsCompressionFlush = false
    private var failure: (any Error)?

    init(fileURL: URL) throws {
        handle = try FileHandle(forWritingTo: fileURL)
        let status = deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            MAX_WBITS + 16,
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
        needsCompressionFlush = true
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
    }

    func synchronize() throws {
        if let failure {
            throw failure
        }
        do {
            if needsCompressionFlush {
                _ = try drain(flush: Z_SYNC_FLUSH)
                needsCompressionFlush = false
            }
            try handle.synchronize()
        } catch {
            failure = error
            throw error
        }
    }

    func finish() throws -> UInt64 {
        guard !isClosed else {
            return 0
        }
        if let failure {
            throw failure
        }

        var status: Int32
        repeat {
            status = try drain(flush: Z_FINISH)
        } while status != Z_STREAM_END

        endCompression()
        try handle.synchronize()
        let byteCount = try handle.offset()
        try handle.close()
        isClosed = true
        return byteCount
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
