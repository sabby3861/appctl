import Foundation
import Testing

@testable import AppctlCore

/// Handcrafted image headers: the inspector reads headers only (no pixel data, no
/// CRC validation), so minimal byte sequences are sufficient and intentional.
enum ImageFixtures {

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func png(width: Int, height: Int, colorType: UInt8, includeTRNS: Bool = false) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // IHDR: length 13, type, width, height, bitDepth, colorType, compression,
        // filter, interlace, fake CRC.
        bytes += be32(13) + Array("IHDR".utf8) + be32(width) + be32(height)
        bytes += [8, colorType, 0, 0, 0] + [0, 0, 0, 0]
        if includeTRNS {
            bytes += be32(0) + Array("tRNS".utf8) + [0, 0, 0, 0]
        }
        bytes += be32(0) + Array("IEND".utf8) + [0, 0, 0, 0]
        return Data(bytes)
    }

    static func jpeg(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8]
        // SOF0: marker, length 11, precision, height, width, one component.
        bytes += [0xFF, 0xC0, 0x00, 0x0B, 0x08]
        bytes += [UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF)]
        bytes += [0x01, 0x01, 0x11, 0x00]
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }

    static func heic() -> Data {
        Data([0x00, 0x00, 0x00, 0x18] + Array("ftypheic".utf8) + [UInt8](repeating: 0, count: 16))
    }

    static func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

func makeTempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Image inspector") struct ImageInspectorTests {

    @Test func pngDimensionsAndNoAlphaForRGB() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(
            ImageFixtures.png(width: 1290, height: 2796, colorType: 2), named: "a.png", in: dir)
        let info = try ImageInspector.inspect(url)
        #expect(info.format == .png)
        #expect(info.width == 1290)
        #expect(info.height == 2796)
        #expect(!info.hasAlpha)
    }

    @Test func pngAlphaDetectedFromColorType() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(
            ImageFixtures.png(width: 100, height: 100, colorType: 6), named: "a.png", in: dir)
        #expect(try ImageInspector.inspect(url).hasAlpha)
    }

    @Test func pngAlphaDetectedFromTRNSChunk() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(
            ImageFixtures.png(width: 100, height: 100, colorType: 2, includeTRNS: true),
            named: "a.png", in: dir)
        #expect(try ImageInspector.inspect(url).hasAlpha)
    }

    @Test func jpegDimensionsParsedFromSOF() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(
            ImageFixtures.jpeg(width: 1320, height: 2868), named: "a.jpg", in: dir)
        let info = try ImageInspector.inspect(url)
        #expect(info.format == .jpeg)
        #expect(info.width == 1320)
        #expect(info.height == 2868)
    }

    @Test func heicDetectedByMagicBytesNotExtension() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(ImageFixtures.heic(), named: "sneaky.png", in: dir)
        #expect(try ImageInspector.inspect(url).format == .heic)
    }

    @Test func unknownFormatThrows() throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ImageFixtures.write(Data("not an image".utf8), named: "a.png", in: dir)
        #expect(throws: AppctlError.self) { try ImageInspector.inspect(url) }
    }
}
