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

/// One already-compressed member to place inside the archive.
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

    var errorDescription: String? {
        switch self {
        case .noMembers:
            "There is nothing to put in the archive."
        case .missingMember(let name):
            "Hozz could not find the export part \(name)."
        case .nameTooLong:
            "The export file name is too long for a ZIP archive."
        }
    }
}

/// Writes a single-entry Zip64 archive whose deflate stream is copied straight
/// from the run's parts.
///
/// ZIP rather than gzip because a stock Mac can open it: Archive Utility is
/// what Finder's own Compress produces, and it handles neither concatenated
/// gzip members nor the 32-bit size field that wraps once an export passes
/// 4 GiB. Both are unavoidable for a Health export of any size.
///
/// Nothing is recompressed. Each part is a raw deflate stream that was ended
/// with a sync flush rather than a final block, so the parts concatenate into
/// one valid deflate stream once a two-byte end-of-stream marker is appended.
/// The entry's CRC is the parts' CRCs combined.
enum ZipArchiveWriter {
    private static let bufferSize = 1 * 1_024 * 1_024

    /// A final, empty, fixed-Huffman deflate block. Valid only at a byte
    /// boundary, which a sync flush guarantees.
    static let deflateTerminator: [UInt8] = [0x03, 0x00]

    private static let zip64Version: UInt16 = 45
    private static let deflateMethod: UInt16 = 8

    static func write(
        members: [ZipMember],
        entryName: String,
        modifiedAt: Date,
        to destinationURL: URL
    ) throws -> UInt64 {
        guard !members.isEmpty else {
            throw ZipArchiveWriterError.noMembers
        }
        for member in members
        where !FileManager.default.fileExists(atPath: member.url.path) {
            throw ZipArchiveWriterError.missingMember(member.url.lastPathComponent)
        }
        let nameBytes = Array(entryName.utf8)
        guard nameBytes.count <= Int(UInt16.max) else {
            throw ZipArchiveWriterError.nameTooLong
        }

        let uncompressedSize = members.reduce(UInt64(0)) {
            $0 + $1.uncompressedByteCount
        }
        let compressedSize = members.reduce(UInt64(0)) {
            $0 + $1.compressedByteCount
        } + UInt64(deflateTerminator.count)
        let crc = combinedCRC(of: members)
        let (dosTime, dosDate) = dosTimestamp(modifiedAt)

        let scratchURL = destinationURL
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

        do {
            let handle = try FileHandle(forWritingTo: scratchURL)
            defer { try? handle.close() }

            try handle.write(
                contentsOf: localFileHeader(
                    nameBytes: nameBytes,
                    crc: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    dosTime: dosTime,
                    dosDate: dosDate
                )
            )

            for member in members {
                let reader = try FileHandle(forReadingFrom: member.url)
                defer { try? reader.close() }
                while true {
                    let chunk = try reader.read(upToCount: bufferSize) ?? Data()
                    guard !chunk.isEmpty else {
                        break
                    }
                    try handle.write(contentsOf: chunk)
                }
            }
            try handle.write(contentsOf: Data(deflateTerminator))

            let centralDirectoryOffset = try handle.offset()
            let centralDirectory = centralDirectoryHeader(
                nameBytes: nameBytes,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                dosTime: dosTime,
                dosDate: dosDate
            )
            try handle.write(contentsOf: centralDirectory)

            try handle.write(
                contentsOf: endOfCentralDirectory(
                    centralDirectoryOffset: centralDirectoryOffset,
                    centralDirectorySize: UInt64(centralDirectory.count)
                )
            )
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            throw error
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: scratchURL, to: destinationURL)

        let size = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

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

    // MARK: - Records

    private static func zip64ExtraField(
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        localHeaderOffset: UInt64?
    ) -> [UInt8] {
        var writer = ByteWriter()
        let payloadSize = UInt16(localHeaderOffset == nil ? 16 : 24)
        writer.u16(0x0001)
        writer.u16(payloadSize)
        writer.u64(uncompressedSize)
        writer.u64(compressedSize)
        if let localHeaderOffset {
            writer.u64(localHeaderOffset)
        }
        return writer.bytes
    }

    private static func localFileHeader(
        nameBytes: [UInt8],
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        dosTime: UInt16,
        dosDate: UInt16
    ) -> Data {
        let extra = zip64ExtraField(
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            localHeaderOffset: nil
        )
        var writer = ByteWriter()
        writer.u32(0x0403_4B50)
        writer.u16(zip64Version)
        writer.u16(0)
        writer.u16(deflateMethod)
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

    private static func centralDirectoryHeader(
        nameBytes: [UInt8],
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        dosTime: UInt16,
        dosDate: UInt16
    ) -> Data {
        let extra = zip64ExtraField(
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            localHeaderOffset: 0
        )
        var writer = ByteWriter()
        writer.u32(0x0201_4B50)
        writer.u16(zip64Version)
        writer.u16(zip64Version)
        writer.u16(0)
        writer.u16(deflateMethod)
        writer.u16(dosTime)
        writer.u16(dosDate)
        writer.u32(crc)
        writer.u32(0xFFFF_FFFF)
        writer.u32(0xFFFF_FFFF)
        writer.u16(UInt16(nameBytes.count))
        writer.u16(UInt16(extra.count))
        writer.u16(0)
        writer.u16(0)
        writer.u16(0)
        writer.u32(0)
        writer.u32(0xFFFF_FFFF)
        writer.raw(nameBytes)
        writer.raw(extra)
        return writer.data
    }

    private static func endOfCentralDirectory(
        centralDirectoryOffset: UInt64,
        centralDirectorySize: UInt64
    ) -> Data {
        var writer = ByteWriter()

        // Zip64 end of central directory record.
        writer.u32(0x0606_4B50)
        writer.u64(44)
        writer.u16(zip64Version)
        writer.u16(zip64Version)
        writer.u32(0)
        writer.u32(0)
        writer.u64(1)
        writer.u64(1)
        writer.u64(centralDirectorySize)
        writer.u64(centralDirectoryOffset)

        // Zip64 end of central directory locator.
        writer.u32(0x0706_4B50)
        writer.u32(0)
        writer.u64(centralDirectoryOffset + centralDirectorySize)
        writer.u32(1)

        // Classic end of central directory, with every field saturated so a
        // reader is forced to consult the Zip64 records above.
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
