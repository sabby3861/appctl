import Foundation

public struct RelationshipRef: Encodable, Sendable {
    public let data: TypeIDRef
    public init(data: TypeIDRef) { self.data = data }
}

public struct TypeIDRef: Encodable, Sendable {
    public let type: String
    public let id: String
    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

public struct VersionCreateRequest: Encodable, Sendable {
    public let data: VersionCreateData
}
public struct VersionCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: VersionCreateAttributes
    public let relationships: VersionCreateRelationships
}
public struct VersionCreateAttributes: Encodable, Sendable {
    public let platform: String
    public let versionString: String
    public let releaseType: String
}
public struct VersionCreateRelationships: Encodable, Sendable { public let app: RelationshipRef }

public struct VersionUpdateRequest: Encodable, Sendable { public let data: VersionUpdateData }
public struct VersionUpdateData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: VersionUpdateAttributes
}
public struct VersionUpdateAttributes: Encodable, Sendable {
    public let versionString: String?
    public let releaseType: String?
}

public struct BuildAttachRequest: Encodable, Sendable { public let data: TypeIDRef }

public struct SubmissionCreateRequest: Encodable, Sendable { public let data: SubmissionCreateData }
public struct SubmissionCreateData: Encodable, Sendable {
    public let type: String
    public let relationships: SubmissionRelationships
}
public struct SubmissionRelationships: Encodable, Sendable { public let appStoreVersion: RelationshipRef }
public struct SubmissionResponse: Decodable, Identifiable {
    public let type: String
    public let id: String
}

public struct PhasedReleaseAttributes: Encodable, Sendable { public let phasedReleaseState: String }
public struct PhasedReleaseResponse: Decodable, Identifiable {
    public let type: String
    public let id: String
}

public struct PhasedReleaseUpdateRequest: Encodable, Sendable {
    public let data: PhasedReleaseUpdateData
    public init(data: PhasedReleaseUpdateData) { self.data = data }
}
public struct PhasedReleaseUpdateData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: PhasedReleaseAttributes
    public init(type: String, id: String, attributes: PhasedReleaseAttributes) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }
}

public struct ComplianceUpdateRequest: Encodable, Sendable { public let data: ComplianceUpdateData }
public struct ComplianceUpdateData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: ComplianceUpdateAttributes
}
public struct ComplianceUpdateAttributes: Encodable, Sendable { public let usesNonExemptEncryption: Bool }

public struct BuildGroupAssignmentBody: Encodable, Sendable { public let data: [TypeIDRef] }

public func resolveAppID(_ override: String?, config: AppctlConfig) throws -> String {
    if let id = override ?? config.defaultAppID { return id }
    throw AppctlError.missingRequiredField(field: "app-id", in: "command arguments or .appctl.toml [app] section")
}
