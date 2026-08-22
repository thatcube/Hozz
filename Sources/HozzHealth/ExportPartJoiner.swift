import Foundation
import HozzStore

enum ExportPartJoinerError: Error, LocalizedError {
    case noParts
    case missingPart(String)

    var errorDescription: String? {
        switch self {
        case .noParts:
            "There are no export parts to join."
        case .missingPart(let name):
            "Hozz could not find the export part \(name)."
        }
    }
}

/// Joins a run's sealed parts into a single artifact.
///
/// Each part is a complete, independently valid gzip member, and concatenated
/// gzip members are themselves a valid gzip stream, so joining is a byte copy
/// with no recompression.
///
/// The join is deliberately *not* an in-place append, and it does not delete
/// its sources. Appending part `k` onto part `0` would be cheaper, but a crash
/// between "bytes appended" and "part forgotten" would append the same member
/// twice on the next attempt, which is exactly the duplication the rest of the
/// design rules out. Instead the parts are streamed into a scratch file that
/// only replaces the destination once it is whole, and the sources stay put
/// until the store has recorded the joined artifact. An interrupted join
/// therefore leaves an unreferenced scratch file for the sweeper and is retried
/// from the beginning.
///
/// The common case — a run that was never interrupted — has a single part and
/// is a move with no copying at all.
enum ExportPartJoiner {
    private static let bufferSize = 1 * 1_024 * 1_024
    static let scratchPrefix = "joining-"

    /// - Parameter sourceURLs: The members to concatenate, in order. The
    ///   destination may appear as the first source, which is how an artifact
    ///   that already absorbed earlier parts folds in parts written since.
    static func join(
        sourceURLs: [URL],
        into destinationURL: URL
    ) throws -> UInt64 {
        guard let first = sourceURLs.first else {
            throw ExportPartJoinerError.noParts
        }
        for url in sourceURLs where !FileManager.default.fileExists(atPath: url.path) {
            throw ExportPartJoinerError.missingPart(url.lastPathComponent)
        }

        if sourceURLs.count == 1 {
            if first != destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: first, to: destinationURL)
            }
            return try byteCount(of: destinationURL)
        }

        let scratchURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: "\(scratchPrefix)\(UUID().uuidString.lowercased()).tmp")
        guard FileManager.default.createFile(
            atPath: scratchURL.path,
            contents: nil,
            attributes: [.protectionKey: StoreLocation.protection]
        ) else {
            throw ExportPartJoinerError.missingPart(scratchURL.lastPathComponent)
        }
        try? StoreLocation.harden(scratchURL)

        do {
            let handle = try FileHandle(forWritingTo: scratchURL)
            defer { try? handle.close() }

            for url in sourceURLs {
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                while true {
                    let chunk = try reader.read(upToCount: bufferSize) ?? Data()
                    guard !chunk.isEmpty else {
                        break
                    }
                    try handle.write(contentsOf: chunk)
                }
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            throw error
        }

        // Nothing observable changes until this point, so a crash before it
        // leaves a scratch file behind and the join is retried whole.
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: scratchURL, to: destinationURL)
        return try byteCount(of: destinationURL)
    }

    private static func byteCount(of url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber
        return size?.uint64Value ?? 0
    }
}
