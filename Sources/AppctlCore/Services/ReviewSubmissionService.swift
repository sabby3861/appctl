import Foundation

/// Written straight to stderr rather than through `OutputFormatter` so it stays
/// visible in `--format json` mode without contaminating stdout.
func printLegacySubmitDeprecationWarning() {
    var s = StandardError.shared
    print(
        "⚠ --legacy-submit uses Apple's deprecated appStoreVersionSubmissions endpoint and will be removed in a future release. The default flow uses reviewSubmissions.",
        to: &s)
}

/// Drives Apple's three-step review submission flow — create a `reviewSubmissions`
/// resource, attach the version as a `reviewSubmissionItems` entry, then mark the
/// submission submitted — plus its cancellation counterpart.
public struct ReviewSubmissionService: Sendable {
    /// States in which a submission still exists and can be acted on.
    static let openStates = ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"]

    private let client: any AppStoreConnectClient

    public init(client: any AppStoreConnectClient) { self.client = client }

    /// Submits a version for review, reusing an in-progress submission when one exists.
    ///
    /// Only `READY_FOR_REVIEW` submissions accept new items, so reuse is limited to
    /// that state. If an open submission has already been sent to review, the item
    /// creation is left to fail so Apple's own error detail reaches the user rather
    /// than being masked by a silent cancel-and-recreate.
    @discardableResult
    public func submit(
        appId: String, platform: String, versionId: String
    ) async throws -> (submission: ReviewSubmission, reused: Bool) {
        let reusable = try await openSubmissions(
            appId: appId, platform: platform, states: ["READY_FOR_REVIEW"])
        let submissionId: String
        let reused: Bool
        if let existing = reusable.first {
            submissionId = existing.id
            reused = true
        } else {
            let created: APIResponse<ReviewSubmission> = try await client.post(
                "reviewSubmissions",
                body: ReviewSubmissionCreateRequest(
                    data: ReviewSubmissionCreateData(
                        type: "reviewSubmissions",
                        attributes: ReviewSubmissionCreateAttributes(platform: platform),
                        relationships: ReviewSubmissionCreateRelationships(
                            app: RelationshipRef(data: TypeIDRef(type: "apps", id: appId))))))
            submissionId = created.data.id
            reused = false
        }
        let _: APIResponse<ReviewSubmissionItem> = try await client.post(
            "reviewSubmissionItems",
            body: ReviewSubmissionItemCreateRequest(
                data: ReviewSubmissionItemCreateData(
                    type: "reviewSubmissionItems",
                    relationships: ReviewSubmissionItemCreateRelationships(
                        reviewSubmission: RelationshipRef(
                            data: TypeIDRef(type: "reviewSubmissions", id: submissionId)),
                        appStoreVersion: RelationshipRef(
                            data: TypeIDRef(type: "appStoreVersions", id: versionId))))))
        let submitted: APIResponse<ReviewSubmission> = try await client.patch(
            "reviewSubmissions/\(submissionId)",
            body: ReviewSubmissionUpdateRequest(
                data: ReviewSubmissionUpdateData(
                    type: "reviewSubmissions", id: submissionId,
                    attributes: ReviewSubmissionUpdateAttributes(submitted: true, canceled: nil))))
        return (submitted.data, reused)
    }

    /// Cancels the app's open review submission. Searches every non-terminal state —
    /// a user canceling is most often canceling an already-submitted one.
    @discardableResult
    public func cancel(appId: String, platform: String) async throws -> ReviewSubmission {
        let open = try await openSubmissions(appId: appId, platform: platform, states: Self.openStates)
        guard let target = open.first else {
            throw AppctlError.resourceNotFound(
                type: "ReviewSubmission",
                identifier: "no open review submission for app \(appId) (\(platform))")
        }
        let canceled: APIResponse<ReviewSubmission> = try await client.patch(
            "reviewSubmissions/\(target.id)",
            body: ReviewSubmissionUpdateRequest(
                data: ReviewSubmissionUpdateData(
                    type: "reviewSubmissions", id: target.id,
                    attributes: ReviewSubmissionUpdateAttributes(submitted: nil, canceled: true))))
        return canceled.data
    }

    /// Resolves the app and platform a version belongs to — the review submission
    /// endpoints are keyed by app, while our version commands take a version ID.
    static func resolveAppAndPlatform(
        versionId: String, client: any AppStoreConnectClient
    ) async throws -> (appId: String, platform: String) {
        let version: APIResponse<AppStoreVersion> = try await client.get("appStoreVersions/\(versionId)")
        guard let platform = version.data.attributes?.platform else {
            throw AppctlError.invalidResponse(
                url: "appStoreVersions/\(versionId)",
                reason: "Version has no platform attribute.")
        }
        let app: APIResponse<App> = try await client.get("appStoreVersions/\(versionId)/app")
        return (app.data.id, platform)
    }

    private func openSubmissions(
        appId: String, platform: String, states: [String]
    ) async throws -> [ReviewSubmission] {
        var page: APIListResponse<ReviewSubmission> = try await client.getList(
            "apps/\(appId)/reviewSubmissions",
            queryItems: [
                URLQueryItem(name: "filter[state]", value: states.joined(separator: ",")),
                URLQueryItem(name: "filter[platform]", value: platform),
            ])
        var results = page.data
        while let next = page.links?.next {
            page = try await client.get(next)
            results.append(contentsOf: page.data)
        }
        return results
    }
}
