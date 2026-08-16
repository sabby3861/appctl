import Foundation

// Models for Apple's current review submission flow (`reviewSubmissions` /
// `reviewSubmissionItems`), which replaces the deprecated `appStoreVersionSubmissions`
// resource.

public struct ReviewSubmission: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: ReviewSubmissionAttributes?
}

public struct ReviewSubmissionAttributes: Decodable {
    public let platform: String?
    public let state: String?
    public let submittedDate: String?
}

public struct ReviewSubmissionItem: Decodable, Identifiable {
    public let type: String
    public let id: String
    public let attributes: ReviewSubmissionItemAttributes?
}

public struct ReviewSubmissionItemAttributes: Decodable {
    public let state: String?
}

public struct ReviewSubmissionCreateRequest: Encodable, Sendable { public let data: ReviewSubmissionCreateData }
public struct ReviewSubmissionCreateData: Encodable, Sendable {
    public let type: String
    public let attributes: ReviewSubmissionCreateAttributes
    public let relationships: ReviewSubmissionCreateRelationships
}
public struct ReviewSubmissionCreateAttributes: Encodable, Sendable { public let platform: String }
public struct ReviewSubmissionCreateRelationships: Encodable, Sendable { public let app: RelationshipRef }

public struct ReviewSubmissionItemCreateRequest: Encodable, Sendable { public let data: ReviewSubmissionItemCreateData }
public struct ReviewSubmissionItemCreateData: Encodable, Sendable {
    public let type: String
    public let relationships: ReviewSubmissionItemCreateRelationships
}
public struct ReviewSubmissionItemCreateRelationships: Encodable, Sendable {
    public let reviewSubmission: RelationshipRef
    public let appStoreVersion: RelationshipRef
}

public struct ReviewSubmissionUpdateRequest: Encodable, Sendable { public let data: ReviewSubmissionUpdateData }
public struct ReviewSubmissionUpdateData: Encodable, Sendable {
    public let type: String
    public let id: String
    public let attributes: ReviewSubmissionUpdateAttributes
}

/// `submitted` and `canceled` are one-way triggers in the API; synthesized encoding
/// omits whichever is nil, so a request only ever carries the intended trigger.
public struct ReviewSubmissionUpdateAttributes: Encodable, Sendable {
    public let submitted: Bool?
    public let canceled: Bool?
}
