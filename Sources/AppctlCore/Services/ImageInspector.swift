import Foundation

public enum ImageFormat: String, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"
}

public struct ImageInfo: Sendable {
    public let format: ImageFormat
    public let width: Int
    public let height: Int
    /// PNG only: color type carries alpha (4/6) or a tRNS transparency chunk exists.
    public let hasAlpha: Bool
}

/// Reads image identity straight from file headers — magic bytes, never the file
/// extension — so a HEIC renamed to `.png` is still detected as HEIC. Header-only by
/// design: no pixel decoding, no ImageIO, so it needs neither valid image data past
/// the header nor any framework beyond Foundation.
public enum ImageInspector {

    public static func inspect(_ url: URL) throws -> ImageInfo {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw AppctlError.fileNotReadable(path: url.path)
        }
        if let info = parsePNG(data) { return info }
        if let info = parseJPEG(data) { return info }
        if isHEIC(data) { return ImageInfo(format: .heic, width: 0, height: 0, hasAlpha: false) }
        throw AppctlError.invalidInput(
            field: "screenshot", value: url.lastPathComponent,
            expected: "A PNG or JPEG file (file header is neither)")
    }

    // MARK: - PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func parsePNG(_ data: Data) -> ImageInfo? {
        guard data.count >= 33, [UInt8](data.prefix(8)) == pngSignature else { return nil }
        // IHDR must be the first chunk: length(4) "IHDR"(4) width(4) height(4)
        // bitDepth(1) colorType(1) …
        guard bytes(data, at: 12, count: 4) == Array("IHDR".utf8) else { return nil }
        let width = be32(data, at: 16)
        let height = be32(data, at: 20)
        let colorType = data[data.startIndex + 25]
        var hasAlpha = colorType == 4 || colorType == 6
        if !hasAlpha { hasAlpha = containsTRNSChunk(data) }
        return ImageInfo(format: .png, width: width, height: height, hasAlpha: hasAlpha)
    }

    /// Walks chunk headers (skipping payloads) looking for tRNS, which must appear
    /// before IDAT per the PNG spec.
    private static func containsTRNSChunk(_ data: Data) -> Bool {
        var offset = 8
        while offset + 8 <= data.count {
            let length = be32(data, at: offset)
            let type = bytes(data, at: offset + 4, count: 4)
            if type == Array("tRNS".utf8) { return true }
            if type == Array("IDAT".utf8) || type == Array("IEND".utf8) { return false }
            offset += 8 + length + 4
        }
        return false
    }

    // MARK: - JPEG

    private static func parseJPEG(_ data: Data) -> ImageInfo? {
        guard data.count >= 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8
        else { return nil }
        var offset = 2
        while offset + 4 <= data.count {
            guard data[data.startIndex + offset] == 0xFF else { return nil }
            let marker = data[data.startIndex + offset + 1]
            if marker == 0xFF {
                offset += 1
                continue
            }
            // Standalone markers (no length payload).
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) {
                offset += 2
                continue
            }
            let length = be16(data, at: offset + 2)
            let isSOF =
                (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF {
                // Segment payload: precision(1) height(2) width(2).
                guard offset + 9 <= data.count else { return nil }
                let height = be16(data, at: offset + 5)
                let width = be16(data, at: offset + 7)
                return ImageInfo(format: .jpeg, width: width, height: height, hasAlpha: false)
            }
            offset += 2 + length
        }
        return nil
    }

    // MARK: - HEIC

    private static let heicBrands: Set<[UInt8]> = Set(
        ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif"]
            .map { Array($0.utf8) })

    private static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12, bytes(data, at: 4, count: 4) == Array("ftyp".utf8) else {
            return false
        }
        return heicBrands.contains(bytes(data, at: 8, count: 4))
    }

    // MARK: - Byte helpers

    private static func bytes(_ data: Data, at offset: Int, count: Int) -> [UInt8] {
        let start = data.startIndex + offset
        return [UInt8](data[start..<start + count])
    }

    private static func be32(_ data: Data, at offset: Int) -> Int {
        let b = bytes(data, at: offset, count: 4)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    private static func be16(_ data: Data, at offset: Int) -> Int {
        let b = bytes(data, at: offset, count: 2)
        return Int(b[0]) << 8 | Int(b[1])
    }
}
