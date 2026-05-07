import Foundation

public struct RelationshipRef: Encodable {
    public let data: TypeIDRef
    public init(data: TypeIDRef) { self.data = data }
}

public struct TypeIDRef: Encodable {
    public let type: String
    public let id: String
    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

public struct VersionCreateRequest: Encodable {
    public let data: VersionCreateData
}
public struct VersionCreateData: Encodable {
    public let type: String
    public let attributes: VersionCreateAttributes
    public let relationships: VersionCreateRelationships
}
public struct VersionCreateAttributes: Encodable {
    public let platform: String
    public let versionString: String
    public let releaseType: String
}
public struct VersionCreateRelationships: Encodable { public let app: RelationshipRef }

public struct VersionUpdateRequest: Encodable { public let data: VersionUpdateData }
public struct VersionUpdateData: Encodable {
    public let type: String
    public let id: String
    public let attributes: VersionUpdateAttributes
}
public struct VersionUpdateAttributes: Encodable {
    public let versionString: String?
    public let releaseType: String?
}

public struct BuildAttachRequest: Encodable { public let data: TypeIDRef }

public struct SubmissionCreateRequest: Encodable { public let data: SubmissionCreateData }
public struct SubmissionCreateData: Encodable {
    public let type: String
    public let relationships: SubmissionRelationships
}
public struct SubmissionRelationships: Encodable { public let appStoreVersion: RelationshipRef }
public struct SubmissionResponse: Decodable, Identifiable {
    public let type: String
    public let id: String
}

public struct PhasedReleaseAttributes: Encodable { public let phasedReleaseState: String }
public struct PhasedReleaseResponse: Decodable, Identifiable {
    public let type: String
    public let id: String
}

public struct PhasedReleaseUpdateRequest: Encodable {
    public let data: PhasedReleaseUpdateData
    public init(data: PhasedReleaseUpdateData) { self.data = data }
}
public struct PhasedReleaseUpdateData: Encodable {
    public let type: String
    public let id: String
    public let attributes: PhasedReleaseAttributes
    public init(type: String, id: String, attributes: PhasedReleaseAttributes) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }
}

public struct ComplianceUpdateRequest: Encodable { public let data: ComplianceUpdateData }
public struct ComplianceUpdateData: Encodable {
    public let type: String
    public let id: String
    public let attributes: ComplianceUpdateAttributes
}
public struct ComplianceUpdateAttributes: Encodable { public let usesNonExemptEncryption: Bool }

public struct BuildGroupAssignmentBody: Encodable { public let data: [TypeIDRef] }

public func resolveAppID(_ override: String?, config: AppctlConfig) throws -> String {
    if let id = override ?? config.defaultAppID { return id }
    throw AppctlError.missingRequiredField(field: "app-id", in: "command arguments or .appctl.toml [app] section")
}
