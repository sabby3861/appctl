import Foundation

// App Store screenshot upload flow. Same reserve → PUT → commit shape as the Build
// Upload API, but the commit differs: appScreenshots take a flat
// `sourceFileChecksum` string plus `uploaded`, not the nested `sourceFileChecksums`
// object buildUploadFiles use — hence separate types.

public struct AppScreenshot: Decodable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let attributes: AppScreenshotAttributes?
}

public struct AppScreenshotAttributes: Decodable, Sendable {
    public let fileName: String?
    public let fileSize: Int64?
    public let sourceFileChecksum: String?
    public let uploadOperations: [UploadOperation]?
}

public struct ScreenshotCreateRequest: Encodable, Sendable {
    public let data: ScreenshotCreateData
    public init(data: ScreenshotCreateData) { self.data = data }
}
public struct ScreenshotCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: ScreenshotCreateAttributes
    public let relationships: ScreenshotCreateRelationships
    public init(
        type: String, attributes: ScreenshotCreateAttributes,
        relationships: ScreenshotCreateRelationships
    ) {
        self.type = type
        self.attributes = attributes
        self.relationships = relationships
    }
}
public struct ScreenshotCreateAttributes: Encodable, Sendable {
    public let fileName: String
    public let fileSize: Int64
    public init(fileName: String, fileSize: Int64) {
        self.fileName = fileName
        self.fileSize = fileSize
    }
}
public struct ScreenshotCreateRelationships: Encodable, Sendable {
    public let appScreenshotSet: RelationshipRef
    public init(appScreenshotSet: RelationshipRef) { self.appScreenshotSet = appScreenshotSet }
}

public struct ScreenshotCommitRequest: Encodable, Sendable {
    public let data: ScreenshotCommitData
    public init(data: ScreenshotCommitData) { self.data = data }
}
public struct ScreenshotCommitData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: ScreenshotCommitAttributes
    public init(type: String, id: String, attributes: ScreenshotCommitAttributes) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }
}
public struct ScreenshotCommitAttributes: Encodable, Sendable {
    public let uploaded: Bool
    public let sourceFileChecksum: String
    public init(uploaded: Bool, sourceFileChecksum: String) {
        self.uploaded = uploaded
        self.sourceFileChecksum = sourceFileChecksum
    }
}

public struct ScreenshotSetCreateRequest: Encodable, Sendable {
    public let data: ScreenshotSetCreateData
    public init(data: ScreenshotSetCreateData) { self.data = data }
}
public struct ScreenshotSetCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: ScreenshotSetCreateAttributes
    public let relationships: ScreenshotSetCreateRelationships
    public init(
        type: String, attributes: ScreenshotSetCreateAttributes,
        relationships: ScreenshotSetCreateRelationships
    ) {
        self.type = type
        self.attributes = attributes
        self.relationships = relationships
    }
}
public struct ScreenshotSetCreateAttributes: Encodable, Sendable {
    public let screenshotDisplayType: String
    public init(screenshotDisplayType: String) { self.screenshotDisplayType = screenshotDisplayType }
}
public struct ScreenshotSetCreateRelationships: Encodable, Sendable {
    public let appStoreVersionLocalization: RelationshipRef
    public init(appStoreVersionLocalization: RelationshipRef) {
        self.appStoreVersionLocalization = appStoreVersionLocalization
    }
}

/// Maps exact pixel dimensions to the ASC `screenshotDisplayType` a file belongs to.
/// Table sourced from Apple's screenshot specifications and fastlane's
/// DEVICE_RESOLUTIONS mapping (both checked 2026-08). Ambiguity note: 2048×2732
/// is valid for both APP_IPAD_PRO_129 and APP_IPAD_PRO_3GEN_129; we resolve to the
/// 3rd-gen type because that is the size App Store Connect requires today.
public enum ScreenshotDimensions {

    public struct Size: Hashable, Sendable {
        public let width: Int
        public let height: Int
        public init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Display types in a stable order for error listings, each with its portrait
    /// sizes. Landscape is the mirrored pair except the 4"/3.5" iPhones, whose
    /// landscape variants drop the status-bar rows (e.g. 1136×600).
    static let table: [(displayType: String, sizes: [Size])] = [
        ("APP_IPHONE_67", mirrored([Size(1320, 2868), Size(1290, 2796), Size(1260, 2736)])),
        ("APP_IPHONE_65", mirrored([Size(1284, 2778), Size(1242, 2688)])),
        ("APP_IPHONE_61", mirrored([Size(1206, 2622), Size(1179, 2556)])),
        ("APP_IPHONE_58", mirrored([Size(1170, 2532), Size(1125, 2436), Size(1080, 2340)])),
        ("APP_IPHONE_55", mirrored([Size(1242, 2208)])),
        ("APP_IPHONE_47", mirrored([Size(750, 1334)])),
        (
            "APP_IPHONE_40",
            [Size(640, 1096), Size(640, 1136), Size(1136, 600), Size(1136, 640)]
        ),
        (
            "APP_IPHONE_35",
            [Size(640, 920), Size(640, 960), Size(960, 600), Size(960, 640)]
        ),
        ("APP_IPAD_PRO_3GEN_129", mirrored([Size(2064, 2752), Size(2048, 2732)])),
        (
            "APP_IPAD_PRO_3GEN_11",
            mirrored([Size(1668, 2420), Size(1668, 2388), Size(1640, 2360), Size(1488, 2266)])
        ),
        ("APP_IPAD_105", mirrored([Size(1668, 2224)])),
        (
            "APP_IPAD_97",
            mirrored([Size(1536, 2048), Size(1536, 2008), Size(768, 1024), Size(768, 1004)])
        ),
    ]

    private static func mirrored(_ sizes: [Size]) -> [Size] {
        sizes + sizes.map { Size($0.height, $0.width) }
    }

    private static let sizeToDisplayType: [Size: String] = {
        var map: [Size: String] = [:]
        // Reversed so earlier (preferred) table entries win duplicate sizes.
        for entry in table.reversed() {
            for size in entry.sizes { map[size] = entry.displayType }
        }
        return map
    }()

    public static func displayType(width: Int, height: Int) -> String? {
        sizeToDisplayType[Size(width, height)]
    }

    /// One line per display type, for validation-failure messages.
    public static func acceptedSizesLines() -> [String] {
        table.map { entry in
            let sizes = entry.sizes.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
            return "\(entry.displayType.displayTypeLabel): \(sizes)"
        }
    }
}
