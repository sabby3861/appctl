import Crypto
import Foundation

/// Disk access for build uploads. HARD REQUIREMENT (review point): the whole archive
/// is never loaded into memory — an IPA can exceed 4 GB, which would OOM a CI runner.
/// Every part read is scoped to exactly one upload operation's byte range via
/// seek + fixed-length read, and the whole-file checksum is computed in bounded chunks.
public enum UploadFileAccess {

    static let checksumChunkSize = 4 * 1024 * 1024

    /// Reads exactly `length` bytes starting at `offset`. Never reads outside the
    /// requested range; a file shorter than `offset + length` is an error, not a
    /// silent short read, because it means the file changed since reservation.
    public static func readRange(of url: URL, offset: Int64, length: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AppctlError.fileNotReadable(path: url.path)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw AppctlError.invalidInput(
                    field: "file", value: url.path,
                    expected:
                        "\(length) bytes at offset \(offset) — the file is shorter than the upload reservation describes; it may have been rebuilt mid-upload"
                )
            }
            return data
        } catch let e as AppctlError {
            throw e
        } catch {
            throw AppctlError.fileNotReadable(path: url.path)
        }
    }

    /// Whole-file MD5 (the algorithm App Store Connect validates commits against),
    /// streamed in bounded chunks.
    public static func md5Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AppctlError.fileNotReadable(path: url.path)
        }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: checksumChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSize(of url: URL) throws -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
        else {
            throw AppctlError.fileNotFound(path: url.path)
        }
        return size
    }
}
