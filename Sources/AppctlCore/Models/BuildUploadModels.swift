import Foundation

// Build Upload API (WWDC25). Field names mirror the documented schema exactly:
// POST v1/buildUploads → POST v1/buildUploadFiles (reservation, returns uploadOperations)
// → PUT each operation's byte range → PATCH v1/buildUploadFiles/{id} (commit with
// uploaded=true + sourceFileChecksums).

public struct BuildUpload: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BuildUploadAttributes?
    public let relationships: BuildUploadRelationships?
}

public struct BuildUploadAttributes: Decodable {
    public let cfBundleShortVersionString: String?
    public let cfBundleVersion: String?
    public let platform: String?
    public let createdDate: String?
    public let uploadedDate: String?
    public let state: BuildUploadStateInfo?
}

/// `state.state` is one of AWAITING_UPLOAD, PROCESSING, FAILED, COMPLETE.
public struct BuildUploadStateInfo: Decodable {
    public let state: String?
    public let errors: [BuildUploadStateDetail]?
    public let warnings: [BuildUploadStateDetail]?
    public let infos: [BuildUploadStateDetail]?
}

public struct BuildUploadStateDetail: Decodable {
    public let code: String?
    public let description: String?
}

public struct BuildUploadRelationships: Decodable {
    public let build: Relationship?
}

public struct BuildUploadFile: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BuildUploadFileAttributes?
}

public struct BuildUploadFileAttributes: Decodable {
    public let fileName: String?
    public let fileSize: Int64?
    public let assetType: String?
    public let uti: String?
    public let assetToken: String?
    public let uploadOperations: [UploadOperation]?
}

/// One PUT the server instructs us to perform. Codable (not just Decodable) because
/// operations are persisted verbatim in the resumable-upload sidecar.
public struct UploadOperation: Codable, Sendable {
    public let method: String?
    public let url: String?
    public let offset: Int64?
    public let length: Int64?
    public let partNumber: Int64?
    public let entityTag: String?
    public let expiration: String?
    public let requestHeaders: [UploadHTTPHeader]?

    public init(
        method: String?, url: String?, offset: Int64?, length: Int64?, partNumber: Int64?,
        entityTag: String? = nil, expiration: String? = nil, requestHeaders: [UploadHTTPHeader]? = nil
    ) {
        self.method = method
        self.url = url
        self.offset = offset
        self.length = length
        self.partNumber = partNumber
        self.entityTag = entityTag
        self.expiration = expiration
        self.requestHeaders = requestHeaders
    }
}

public struct UploadHTTPHeader: Codable, Sendable {
    public let name: String?
    public let value: String?
    public init(name: String?, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct BuildUploadCreateRequest: Encodable, Sendable {
    public let data: BuildUploadCreateData
    public init(data: BuildUploadCreateData) { self.data = data }
}
public struct BuildUploadCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: BuildUploadCreateAttributes
    public let relationships: BuildUploadCreateRelationships
    public init(
        type: String, attributes: BuildUploadCreateAttributes,
        relationships: BuildUploadCreateRelationships
    ) {
        self.type = type
        self.attributes = attributes
        self.relationships = relationships
    }
}
public struct BuildUploadCreateAttributes: Encodable, Sendable {
    public let cfBundleShortVersionString: String
    public let cfBundleVersion: String
    public let platform: String
    public init(cfBundleShortVersionString: String, cfBundleVersion: String, platform: String) {
        self.cfBundleShortVersionString = cfBundleShortVersionString
        self.cfBundleVersion = cfBundleVersion
        self.platform = platform
    }
}
public struct BuildUploadCreateRelationships: Encodable, Sendable {
    public let app: RelationshipRef
    public init(app: RelationshipRef) { self.app = app }
}

public struct BuildUploadFileCreateRequest: Encodable, Sendable {
    public let data: BuildUploadFileCreateData
    public init(data: BuildUploadFileCreateData) { self.data = data }
}
public struct BuildUploadFileCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: BuildUploadFileCreateAttributes
    public let relationships: BuildUploadFileCreateRelationships
    public init(
        type: String, attributes: BuildUploadFileCreateAttributes,
        relationships: BuildUploadFileCreateRelationships
    ) {
        self.type = type
        self.attributes = attributes
        self.relationships = relationships
    }
}
public struct BuildUploadFileCreateAttributes: Encodable, Sendable {
    public let assetType: String
    public let fileName: String
    public let fileSize: Int64
    public let uti: String
    public init(assetType: String, fileName: String, fileSize: Int64, uti: String) {
        self.assetType = assetType
        self.fileName = fileName
        self.fileSize = fileSize
        self.uti = uti
    }
}
public struct BuildUploadFileCreateRelationships: Encodable, Sendable {
    public let buildUpload: RelationshipRef
    public init(buildUpload: RelationshipRef) { self.buildUpload = buildUpload }
}

/// Commit request: tells App Store Connect all parts are uploaded and provides the
/// whole-file checksum it validates the received bytes against.
public struct BuildUploadFileCommitRequest: Encodable, Sendable {
    public let data: BuildUploadFileCommitData
    public init(data: BuildUploadFileCommitData) { self.data = data }
}
public struct BuildUploadFileCommitData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: BuildUploadFileCommitAttributes
    public init(type: String, id: String, attributes: BuildUploadFileCommitAttributes) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }
}
public struct BuildUploadFileCommitAttributes: Encodable, Sendable {
    public let uploaded: Bool
    public let sourceFileChecksums: SourceFileChecksums
    public init(uploaded: Bool, sourceFileChecksums: SourceFileChecksums) {
        self.uploaded = uploaded
        self.sourceFileChecksums = sourceFileChecksums
    }
}
public struct SourceFileChecksums: Encodable, Sendable {
    public let file: FileChecksumValue
    public init(file: FileChecksumValue) { self.file = file }
}
public struct FileChecksumValue: Encodable, Sendable {
    public let algorithm: String
    public let hash: String
    public init(algorithm: String, hash: String) {
        self.algorithm = algorithm
        self.hash = hash
    }
}
