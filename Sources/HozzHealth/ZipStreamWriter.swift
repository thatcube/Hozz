import Foundation
import HozzStore
import zlib

/// Builds the little-endian byte sequences a ZIP file is made of.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func raw(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    var data: Data {
        Data(bytes)
    }
}

/// One already-compressed segment to copy into an entry verbatim.
struct ZipMember {
    let url: URL
    let compressedByteCount: UInt64
    let uncompressedByteCount: UInt64
    let crc32: UInt32
}

enum ZipArchiveWriterError: Error, LocalizedError {
    case noMembers
    case missingMember(String)
    case nameTooLong
    case entryAlreadyOpen
    case noOpenEntry

    var errorDescription: String? {
        switch self {
        case .noMembers:
            "There is nothing to put in the archive."
        case .missingMember(let name):
            "Hozz could not find the export part \(name)."
        case .nameTooLong:
            "An export file name is too long for a ZIP archive."
        case .entryAlreadyOpen:
            "An archive entry is already open."
        case .noOpenEntry:
            "There is no open archive entry to write to."
        }
    }
}

/// Writes a Zip64 archive one entry at a time.
///
/// ZIP rather than gzip because a stock Mac can open it: Archive Utility is
/// what Finder's own Compress produces, and it handles neither concatenated
/// gzip members nor the 32-bit size field that wraps once an export passes
/// 4 GiB. Both are unavoidable for a Health export of any size.
///
/// Two ways to add an entry:
///
/// - ``addEntry(name:copying:)`` copies already-compressed parts verbatim. The
///   parts were written as raw deflate ended with a sync flush rather than a
///   final block, so they concatenate into one valid deflate stream once a
///   two-byte end marker is appended. Nothing is recompressed.
/// - ``beginEntry(name:)`` compresses as it is written, for entries that are
///   produced rather than copied.
final class ZipStreamWriter {
    /// A final, empty, fixed-Huffman deflate block. Valid only at a byte
    /// boundary, which a sync flush guarantees.
    static let deflateTerminator: [UInt8] = [0x03, 0x00]

    private static let zip64Version: UInt16 = 45
    private static let deflateMethod: UInt16 = 8
    private static let bufferSize = 1 * 1_024 * 1_024

    private struct CentralEntry {
        let nameBytes: [UInt8]
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let headerOffset: UInt64
    }

    /// A class, not a struct, and holding the `z_stream` through a stable
    /// allocation. zlib checks that its internal state still points back at the
    /// same `z_stream` address, so copying the struct — which Swift does freely
    /// for value types — makes every later call fail with `Z_STREAM_ERROR`.
    private final class OpenEntry {
        let nameBytes: [UInt8]
        let headerOffset: UInt64
        let stream: UnsafeMutablePointer<z_stream>
        var crc: uLong = 0
        var uncompressedSize: UInt64 = 0

        init(nameBytes: [UInt8], headerOffset: UInt64) {
            self.nameBytes = nameBytes
            self.headerOffset = headerOffset
            stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
        }

        deinit {
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
    }

    private let handle: FileHandle
    private let destinationURL: URL
    private let scratchURL: URL
    private let dosTime: UInt16
    private let dosDate: UInt16

    private var entries: [CentralEntry] = []
    private var openEntry: OpenEntry?
    private var isFinished = false

    init(destinationURL: URL, modifiedAt: Date) throws {
        self.destinationURL = destinationURL
        self.scratchURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: "zipping-\(UUID().uuidString.lowercased()).tmp")

        guard FileManager.default.createFile(
            atPath: scratchURL.path,
            contents: nil,
            attributes: [.protectionKey: StoreLocation.protection]
        ) else {
            throw ZipArchiveWriterError.missingMember(scratchURL.lastPathComponent)
        }
        try? StoreLocation.harden(scratchURL)
        handle = try FileHandle(forWritingTo: scratchURL)

        let stamp = Self.dosTimestamp(modifiedAt)
        dosTime = stamp.time
        dosDate = stamp.date
    }

    // MARK: - Copying pre-compressed parts

    func addEntry(name: String, copying members: [ZipMember]) throws {
        guard openEntry == nil else {
            throw ZipArchiveWriterError.entryAlreadyOpen
        }
        guard !members.isEmpty else {
            throw ZipArchiveWriterError.noMembers
        }
        for member in members
        where !FileManager.default.fileExists(atPath: member.url.path) {
            throw ZipArchiveWriterError.missingMember(member.url.lastPathComponent)
        }

        let nameBytes = try Self.nameBytes(name)
        let headerOffset = try handle.offset()
        let uncompressedSize = members.reduce(UInt64(0)) {
            $0 + $1.uncompressedByteCount
        }
        let compressedSize = members.reduce(UInt64(0)) {
            $0 + $1.compressedByteCount
        } + UInt64(Self.deflateTerminator.count)
        let crc = Self.combinedCRC(of: members)

        try handle.write(
            contentsOf: localFileHeader(
                nameBytes: nameBytes,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize
            )
        )
        for member in members {
            let reader = try FileHandle(forReadingFrom: member.url)
            defer { try? reader.close() }
            while true {
                let chunk = try reader.read(upToCount: Self.bufferSize) ?? Data()
                guard !chunk.isEmpty else {
                    break
                }
                try handle.write(contentsOf: chunk)
            }
        }
        try handle.write(contentsOf: Data(Self.deflateTerminator))

        entries.append(
            CentralEntry(
                nameBytes: nameBytes,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                headerOffset: headerOffset
            )
        )
    }

    // MARK: - Streaming a produced entry

    func beginEntry(name: String) throws {
        guard openEntry == nil else {
            throw ZipArchiveWriterError.entryAlreadyOpen
        }

        let nameBytes = try Self.nameBytes(name)
        let headerOffset = try handle.offset()
        let entry = OpenEntry(nameBytes: nameBytes, headerOffset: headerOffset)
        let status = deflateInit2_(
            entry.stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw ExportOutputError.compressionInitialization(status)
        }

        // Sizes are unknown until the entry closes, so a placeholder header is
        // written now and patched in place once they are known.
        try handle.write(
            contentsOf: localFileHeader(
                nameBytes: nameBytes,
                crc: 0,
                compressedSize: 0,
                uncompressedSize: 0
            )
        )
        openEntry = entry
    }

    func write(_ data: Data) throws {
        guard let entry = openEntry else {
            throw ZipArchiveWriterError.noOpenEntry
        }
        guard !data.isEmpty else {
            return
        }

        try data.withUnsafeBytes { inputBytes in
            guard let input = inputBytes.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            entry.stream.pointee.next_in = UnsafeMutablePointer(mutating: input)
            entry.stream.pointee.avail_in = uInt(data.count)
            defer {
                entry.stream.pointee.next_in = nil
                entry.stream.pointee.avail_in = 0
            }
            while entry.stream.pointee.avail_in > 0 {
                _ = try drain(entry.stream, flush: Z_NO_FLUSH)
            }
        }
        entry.uncompressedSize += UInt64(data.count)
        entry.crc = RawExportOutput.updateCRC(entry.crc, with: data)
    }

    func endEntry() throws {
        guard let entry = openEntry else {
            throw ZipArchiveWriterError.noOpenEntry
        }

        var status = Z_OK
        repeat {
            status = try drain(entry.stream, flush: Z_FINISH)
        } while status != Z_STREAM_END
        deflateEnd(entry.stream)

        let endOffset = try handle.offset()
        let compressedSize = endOffset - entry.headerOffset
            - UInt64(30 + entry.nameBytes.count + 20)
        let crc = UInt32(truncatingIfNeeded: entry.crc)

        try patch(
            headerOffset: entry.headerOffset,
            nameLength: entry.nameBytes.count,
            crc: crc,
            compressedSize: compressedSize,
            uncompressedSize: entry.uncompressedSize
        )
        try handle.seekToEnd()

        entries.append(
            CentralEntry(
                nameBytes: entry.nameBytes,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: entry.uncompressedSize,
                headerOffset: entry.headerOffset
            )
        )
        openEntry = nil
    }

    // MARK: - Finishing

    @discardableResult
    func finish() throws -> UInt64 {
        guard !isFinished else {
            return 0
        }
        guard openEntry == nil else {
            throw ZipArchiveWriterError.entryAlreadyOpen
        }
        guard !entries.isEmpty else {
            throw ZipArchiveWriterError.noMembers
        }

        let centralDirectoryOffset = try handle.offset()
        var directory = Data()
        for entry in entries {
            directory.append(centralDirectoryHeader(entry))
        }
        try handle.write(contentsOf: directory)
        try handle.write(
            contentsOf: endOfCentralDirectory(
                entryCount: UInt64(entries.count),
                centralDirectoryOffset: centralDirectoryOffset,
                centralDirectorySize: UInt64(directory.count)
            )
        )
        try handle.synchronize()
        try handle.close()
        isFinished = true

        // Nothing observable changes until this point, so a crash before it
        // leaves a scratch file behind and the archive is rebuilt from scratch.
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: scratchURL, to: destinationURL)

        let size = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

    func abandon() {
        guard !isFinished else {
            return
        }
        if let entry = openEntry {
            deflateEnd(entry.stream)
            openEntry = nil
        }
        try? handle.close()
        try? FileManager.default.removeItem(at: scratchURL)
        isFinished = true
    }

    deinit {
        abandon()
    }

    // MARK: - Helpers

    static func combinedCRC(of members: [ZipMember]) -> UInt32 {
        members.reduce(UInt32(0)) { combined, member in
            guard member.uncompressedByteCount > 0 else {
                return combined
            }
            return UInt32(
                truncatingIfNeeded: crc32_combine(
                    uLong(combined),
                    uLong(member.crc32),
                    Int(member.uncompressedByteCount)
                )
            )
        }
    }

    private static func nameBytes(_ name: String) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw ZipArchiveWriterError.nameTooLong
        }
        return bytes
    }

    private func drain(
        _ stream: UnsafeMutablePointer<z_stream>,
        flush: Int32
    ) throws -> Int32 {
        var output = [UInt8](repeating: 0, count: 64 * 1_024)
        var status = Z_OK

        repeat {
            let produced: Int = try output.withUnsafeMutableBytes { outputBytes in
                stream.pointee.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.pointee.avail_out = uInt(outputBytes.count)
                status = deflate(stream, flush)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw ExportOutputError.compressionFailed(status)
                }
                return outputBytes.count - Int(stream.pointee.avail_out)
            }
            if produced > 0 {
                try handle.write(contentsOf: Data(output.prefix(produced)))
            }
        } while stream.pointee.avail_in > 0
            || (flush != Z_NO_FLUSH && stream.pointee.avail_out == 0)

        return status
    }

    private func patch(
        headerOffset: UInt64,
        nameLength: Int,
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64
    ) throws {
        var crcWriter = ByteWriter()
        crcWriter.u32(crc)
        try handle.seek(toOffset: headerOffset + 14)
        try handle.write(contentsOf: crcWriter.data)

        var sizeWriter = ByteWriter()
        sizeWriter.u64(uncompressedSize)
        sizeWriter.u64(compressedSize)
        try handle.seek(toOffset: headerOffset + 30 + UInt64(nameLength) + 4)
        try handle.write(contentsOf: sizeWriter.data)
    }

    private func zip64ExtraField(
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        localHeaderOffset: UInt64?
    ) -> [UInt8] {
        var writer = ByteWriter()
        writer.u16(0x0001)
        writer.u16(UInt16(localHeaderOffset == nil ? 16 : 24))
        writer.u64(uncompressedSize)
        writer.u64(compressedSize)
        if let localHeaderOffset {
            writer.u64(localHeaderOffset)
        }
        return writer.bytes
    }

    private func localFileHeader(
        nameBytes: [UInt8],
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64
    ) -> Data {
        let extra = zip64ExtraField(
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            localHeaderOffset: nil
        )
        var writer = ByteWriter()
        writer.u32(0x0403_4B50)
        writer.u16(Self.zip64Version)
        writer.u16(0)
        writer.u16(Self.deflateMethod)
        writer.u16(dosTime)
        writer.u16(dosDate)
        writer.u32(crc)
        // The real sizes live in the Zip64 extra field.
        writer.u32(0xFFFF_FFFF)
        writer.u32(0xFFFF_FFFF)
        writer.u16(UInt16(nameBytes.count))
        writer.u16(UInt16(extra.count))
        writer.raw(nameBytes)
        writer.raw(extra)
        return writer.data
    }

    private func centralDirectoryHeader(_ entry: CentralEntry) -> Data {
        let extra = zip64ExtraField(
            uncompressedSize: entry.uncompressedSize,
            compressedSize: entry.compressedSize,
            localHeaderOffset: entry.headerOffset
        )
        var writer = ByteWriter()
        writer.u32(0x0201_4B50)
        writer.u16(Self.zip64Version)
        writer.u16(Self.zip64Version)
        writer.u16(0)
        writer.u16(Self.deflateMethod)
        writer.u16(dosTime)
        writer.u16(dosDate)
        writer.u32(entry.crc32)
        writer.u32(0xFFFF_FFFF)
        writer.u32(0xFFFF_FFFF)
        writer.u16(UInt16(entry.nameBytes.count))
        writer.u16(UInt16(extra.count))
        writer.u16(0)
        writer.u16(0)
        writer.u16(0)
        writer.u32(0)
        writer.u32(0xFFFF_FFFF)
        writer.raw(entry.nameBytes)
        writer.raw(extra)
        return writer.data
    }

    private func endOfCentralDirectory(
        entryCount: UInt64,
        centralDirectoryOffset: UInt64,
        centralDirectorySize: UInt64
    ) -> Data {
        var writer = ByteWriter()

        writer.u32(0x0606_4B50)
        writer.u64(44)
        writer.u16(Self.zip64Version)
        writer.u16(Self.zip64Version)
        writer.u32(0)
        writer.u32(0)
        writer.u64(entryCount)
        writer.u64(entryCount)
        writer.u64(centralDirectorySize)
        writer.u64(centralDirectoryOffset)

        writer.u32(0x0706_4B50)
        writer.u32(0)
        writer.u64(centralDirectoryOffset + centralDirectorySize)
        writer.u32(1)

        // Classic record, saturated so a reader consults the Zip64 records.
        writer.u32(0x0605_4B50)
        writer.u16(0)
        writer.u16(0)
        writer.u16(0xFFFF)
        writer.u16(0xFFFF)
        writer.u32(0xFFFF_FFFF)
        writer.u32(0xFFFF_FFFF)
        writer.u16(0)

        return writer.data
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max((parts.year ?? 1_980) - 1_980, 0)
        let time =
            UInt16((parts.hour ?? 0) << 11)
            | UInt16((parts.minute ?? 0) << 5)
            | UInt16((parts.second ?? 0) / 2)
        let dateValue =
            UInt16(year << 9)
            | UInt16((parts.month ?? 1) << 5)
            | UInt16(parts.day ?? 1)
        return (time, dateValue)
    }
}
