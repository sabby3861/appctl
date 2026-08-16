import Foundation

public struct APIResponse<T: Decodable>: Decodable {
    public let data: T
    public let included: [IncludedResource]?
    public let links: PageLinks?
    public let meta: ResponseMeta?
}

/// Like `APIResponse`, but accepts `data: null`. App Store Connect returns this shape
/// from to-one related-resource fetches (e.g. `/appStoreVersions/{id}/appStoreVersionPhasedRelease`)
/// when the relationship currently has no associated record.
public struct OptionalAPIResponse<T: Decodable>: Decodable {
    public let data: T?
    public let links: PageLinks?
}

public struct APIListResponse<T: Decodable>: Decodable {
    public let data: [T]
    public let included: [IncludedResource]?
    public let links: PageLinks?
    public let meta: ResponseMeta?
}

public struct PageLinks: Decodable {
    public let this: String?
    public let first: String?
    public let next: String?
    enum CodingKeys: String, CodingKey {
        case this = "self"
        case first
        case next
    }
}

public struct ResponseMeta: Decodable { public let paging: PagingInfo? }
public struct PagingInfo: Decodable {
    public let total: Int?
    public let limit: Int?
}

public struct IncludedResource: Decodable {
    public let type: String
    public let id: String
    public let attributes: [String: AnyCodable]?
}

public struct APIErrorResponse: Decodable { public let errors: [APIErrorDetail] }
public struct APIErrorDetail: Decodable, Sendable {
    public let id: String?
    public let status: String
    public let code: String
    public let title: String
    public let detail: String?
    public let source: APIErrorSource?
}
public struct APIErrorSource: Decodable, Sendable {
    public let pointer: String?
    public let parameter: String?
}

public struct App: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: AppAttributes?
    public let relationships: AppRelationships?
}
public struct AppAttributes: Decodable {
    public let name: String?
    public let bundleId: String?
    public let sku: String?
    public let primaryLocale: String?
    public let contentRightsDeclaration: String?
    public let isOrEverWasMadeForKids: Bool?
    public let availableInNewTerritories: Bool?
}
public struct AppRelationships: Decodable {
    public let appStoreVersions: Relationship?
    public let builds: Relationship?
    public let betaGroups: Relationship?
}

public struct Build: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BuildAttributes?
    public let relationships: BuildRelationships?
}
public struct BuildAttributes: Decodable {
    public let version: String?
    public let uploadedDate: String?
    public let expirationDate: String?
    public let expired: Bool?
    public let minOsVersion: String?
    public let processingState: String?
    public let buildAudienceType: String?
    public let usesNonExemptEncryption: Bool?
}
public struct BuildRelationships: Decodable {
    public let app: Relationship?
    public let appStoreVersion: Relationship?
    public let preReleaseVersion: Relationship?
}

public struct AppStoreVersion: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: AppStoreVersionAttributes?
}
public struct AppStoreVersionAttributes: Decodable {
    public let platform: String?
    public let versionString: String?
    public let appStoreState: String?
    public let releaseType: String?
    public let earliestReleaseDate: String?
    public let createdDate: String?
}

public struct Certificate: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: CertificateAttributes?
}
public struct CertificateAttributes: Decodable {
    public let name: String?
    public let certificateType: String?
    public let displayName: String?
    public let serialNumber: String?
    public let platform: String?
    public let expirationDate: String?
}

public struct Profile: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: ProfileAttributes?
}
public struct ProfileAttributes: Decodable {
    public let name: String?
    public let profileType: String?
    public let profileState: String?
    public let uuid: String?
    public let platform: String?
    public let expirationDate: String?
}

public struct BetaGroup: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BetaGroupAttributes?
}
public struct BetaGroupAttributes: Decodable {
    public let name: String?
    public let isInternalGroup: Bool?
    public let publicLinkEnabled: Bool?
    public let publicLinkLimit: Int?
    public let publicLink: String?
    public let feedbackEnabled: Bool?
    public let createdDate: String?
}

public struct BetaTester: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BetaTesterAttributes?
}
public struct BetaTesterAttributes: Decodable {
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let inviteType: String?
    public let state: String?
}

public struct Device: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: DeviceAttributes?
}
public struct DeviceAttributes: Decodable {
    public let name: String?
    public let platform: String?
    public let udid: String?
    public let deviceClass: String?
    public let status: String?
    public let model: String?
    public let addedDate: String?
}

public struct BundleID: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: BundleIDAttributes?
}
public struct BundleIDAttributes: Decodable {
    public let name: String?
    public let identifier: String?
    public let platform: String?
}

public struct Relationship: Decodable {
    public let links: RelationshipLinks?
    public let data: RelationshipData?
    public let meta: ResponseMeta?
}
public struct RelationshipLinks: Decodable {
    public let this: String?
    public let related: String?
    enum CodingKeys: String, CodingKey {
        case this = "self"
        case related
    }
}
public struct RelationshipData: Decodable {
    public let type: String?
    public let id: String?
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            type = try c.decodeIfPresent(String.self, forKey: .type)
            id = try c.decodeIfPresent(String.self, forKey: .id)
        } else {
            type = nil
            id = nil
        }
    }
    enum CodingKeys: String, CodingKey { case type, id }
}

public struct AnyCodable: Decodable {
    public let value: Any
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else if let v = try? c.decode([AnyCodable].self) {
            value = v.map { $0.value }
        } else if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var boolValue: Bool? { value as? Bool }
    public var doubleValue: Double? { value as? Double }
}
