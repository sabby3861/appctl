import Foundation
import Testing

@testable import AppctlCore

/// Command-seam tests: each suite drives a command's `execute(client:...)` seam with
/// the mock and asserts the exact requests it issues. Service internals (submission
/// reuse) are covered in ReviewSubmissionTests and pagination in PaginationTests —
/// not repeated here.

private func quietOutput() -> OutputFormatter {
    OutputFormatter(format: .json, noColor: true)
}

@Suite("Apps list command") struct AppsListCommandTests {
    private static let appsList = """
        {"data":[{"type":"apps","id":"app-1","attributes":{"name":"My App","bundleId":"com.example.app",\
        "sku":"SKU1","primaryLocale":"en-US"}}]}
        """

    @Test func requestsAppsWithFieldsAndLimit() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.appsList)

        try await AppsCommand.List.execute(
            client: mock, output: quietOutput(), bundleId: nil, name: nil, limit: 50, pageSize: 200)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "apps")
        let items = try #require(requests[0].queryItems)
        #expect(items.contains(URLQueryItem(name: "fields[apps]", value: "name,bundleId,sku,primaryLocale")))
        #expect(
            items.contains(URLQueryItem(name: "limit", value: "50")),
            "per-page limit shrinks to the total limit when smaller than the page size")
    }

    @Test func rejectsOutOfRangePageSize() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            try await AppsCommand.List.execute(
                client: mock, output: quietOutput(), bundleId: nil, name: nil, limit: nil, pageSize: 999)
        }
        #expect(await mock.requests.isEmpty, "validation must fail before any request is issued")
    }

    @Test func appliesBundleIdAndNameFilters() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.appsList)

        try await AppsCommand.List.execute(
            client: mock, output: quietOutput(), bundleId: "com.example.app", name: "My App",
            limit: 200, pageSize: 200)

        let items = try #require(await mock.requests.first?.queryItems)
        #expect(items.contains(URLQueryItem(name: "filter[bundleId]", value: "com.example.app")))
        #expect(items.contains(URLQueryItem(name: "filter[name]", value: "My App")))
    }
}

@Suite("Builds list command") struct BuildsListCommandTests {
    private static let buildsList = """
        {"data":[{"type":"builds","id":"build-1","attributes":{"version":"7","processingState":"VALID",\
        "expired":false,"usesNonExemptEncryption":false}}]}
        """

    @Test func requestsBuildsSortedByUploadDate() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.buildsList)

        try await BuildsCommand.List.execute(
            client: mock, output: quietOutput(), appId: nil, state: nil, version: nil,
            limit: 20, pageSize: 200, expired: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "builds")
        let items = try #require(requests[0].queryItems)
        #expect(items.contains(URLQueryItem(name: "sort", value: "-uploadedDate")))
        #expect(!items.contains { $0.name == "filter[app]" }, "no app filter without an app id")
    }

    @Test func appliesFiltersAndUppercasesState() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.buildsList)

        try await BuildsCommand.List.execute(
            client: mock, output: quietOutput(), appId: "app-1", state: "valid", version: "7",
            limit: 20, pageSize: 200, expired: true)

        let items = try #require(await mock.requests.first?.queryItems)
        #expect(items.contains(URLQueryItem(name: "filter[app]", value: "app-1")))
        #expect(items.contains(URLQueryItem(name: "filter[processingState]", value: "VALID")))
        #expect(items.contains(URLQueryItem(name: "filter[version]", value: "7")))
        #expect(items.contains(URLQueryItem(name: "filter[expired]", value: "true")))
    }
}

@Suite("Versions submit command") struct VersionsSubmitCommandTests {
    private static let version = """
        {"data":{"type":"appStoreVersions","id":"ver-1","attributes":{"platform":"IOS","versionString":"2.0"}}}
        """
    private static let app = #"{"data":{"type":"apps","id":"app-1","attributes":{"name":"My App"}}}"#
    private static let noOpenSubmissions = #"{"data":[]}"#
    private static let submission = """
        {"data":{"type":"reviewSubmissions","id":"sub-1","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"}}}
        """
    private static let submissionItem = """
        {"data":{"type":"reviewSubmissionItems","id":"item-1","attributes":{"state":"READY_FOR_REVIEW"}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: true,
            legacySubmit: false, nextActions: NextActions(propagatedFlags: []))

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil, "--dry-run produces no success envelope")
    }

    @Test func newFlowResolvesAppThenDrivesReviewSubmission() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.version)
        await mock.queue(Self.app)
        await mock.queue(Self.noOpenSubmissions)
        await mock.queue(Self.submission)
        await mock.queue(Self.submissionItem)
        await mock.queue(Self.submission)

        let outcome = try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false,
            legacySubmit: false, nextActions: NextActions(propagatedFlags: []))

        let requests = await mock.requests
        try #require(requests.count == 6)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST", "POST", "PATCH"])
        #expect(requests[0].path == "appStoreVersions/ver-1")
        #expect(requests[1].path == "appStoreVersions/ver-1/app")
        #expect(requests[2].path == "apps/app-1/reviewSubmissions")
        #expect(requests[3].path == "reviewSubmissions")
        #expect(requests[4].path == "reviewSubmissionItems")
        #expect(requests[5].path == "reviewSubmissions/sub-1")

        let itemBody = try jsonObject(requests[4].body)
        let versionRef = nested(itemBody, "data", "relationships", "appStoreVersion", "data")
        #expect(versionRef["id"] as? String == "ver-1")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "version_id": .string("ver-1"),
                    "submission_id": .string("sub-1"),
                    "submission_state": .string("READY_FOR_REVIEW"),
                    "reused": .bool(false),
                ]))
        #expect(outcome?.next == ["reject": "appctl versions reject ver-1"])
    }

    @Test func legacyFlagPostsDeprecatedSubmissionEndpoint() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appStoreVersionSubmissions","id":"legacy-1"}}"#)

        let outcome = try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false,
            legacySubmit: true, nextActions: NextActions(propagatedFlags: []))

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "appStoreVersionSubmissions")
        let ref = nested(try jsonObject(requests[0].body), "data", "relationships", "appStoreVersion", "data")
        #expect(ref["id"] as? String == "ver-1")
        #expect(
            try #require(outcome).data
                == .object(["version_id": .string("ver-1"), "submission_id": .string("legacy-1")]))
    }

    @Test func apiErrorPropagatesUntouched() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.failNext(
            "GET", "appStoreVersions/ver-1",
            withErrorBody: """
                {"errors":[{"status":"404","code":"NOT_FOUND","title":"Not found.",\
                "detail":"No appStoreVersions with id 'ver-1'."}]}
                """)

        await #expect(throws: AppctlError.self) {
            try await VersionsCommand.Submit.execute(
                client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false,
                legacySubmit: false, nextActions: NextActions(propagatedFlags: []))
        }
    }
}

@Suite("Builds set-compliance command") struct BuildsSetComplianceCommandTests {
    private static let build = """
        {"data":{"type":"builds","id":"build-1","attributes":{"version":"7","processingState":"VALID",\
        "expired":false,"usesNonExemptEncryption":false}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await BuildsCommand.SetCompliance.execute(
            client: mock, output: quietOutput(), buildId: "build-1", usesEncryption: true,
            dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil, "--dry-run produces no success envelope")
    }

    @Test func patchesComplianceAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.build)

        let outcome = try await BuildsCommand.SetCompliance.execute(
            client: mock, output: quietOutput(), buildId: "build-1", usesEncryption: false,
            dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "builds/build-1")
        let attrs = nested(try jsonObject(requests[0].body), "data", "attributes")
        #expect(attrs["usesNonExemptEncryption"] as? Bool == false)

        #expect(
            try #require(outcome).data
                == .object([
                    "id": .string("build-1"),
                    "uses_non_exempt_encryption": .bool(false),
                ]))
    }
}

@Suite("TestFlight distribute command") struct TestFlightDistributeCommandTests {
    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await TestFlightCommand.Distribute.execute(
            client: mock, output: quietOutput(), buildId: "build-1", groupId: "group-1",
            dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil, "--dry-run produces no success envelope")
    }

    @Test func postsBuildToGroupRelationshipAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await TestFlightCommand.Distribute.execute(
            client: mock, output: quietOutput(), buildId: "build-1", groupId: "group-1",
            dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "betaGroups/group-1/relationships/builds")
        let body = try jsonObject(requests[0].body)
        let refs = try #require(body["data"] as? [[String: Any]])
        #expect(refs.first?["id"] as? String == "build-1")

        #expect(
            try #require(outcome).data
                == .object([
                    "build_id": .string("build-1"),
                    "group_id": .string("group-1"),
                ]))
    }
}

@Suite("Screenshots delete command") struct ScreenshotsDeleteCommandTests {
    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await ScreenshotsCommand.Delete.execute(
            client: mock, output: quietOutput(), screenshotId: "shot-1", dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func deletesScreenshotAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await ScreenshotsCommand.Delete.execute(
            client: mock, output: quietOutput(), screenshotId: "shot-1", dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "DELETE")
        #expect(requests[0].path == "appScreenshots/shot-1")
        #expect(
            try #require(outcome).data
                == .object(["id": .string("shot-1"), "deleted": .bool(true)]))
    }
}

@Suite("Reviews respond command") struct ReviewsRespondCommandTests {
    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await ReviewCommand.RespondReview.execute(
            client: mock, output: quietOutput(), reviewId: "rev-1", response: "Thanks!",
            dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func oversizedResponseFailsBeforeAnyRequest() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            _ = try await ReviewCommand.RespondReview.execute(
                client: mock, output: quietOutput(), reviewId: "rev-1",
                response: String(repeating: "x", count: 5971), dryRun: false)
        }
        #expect(await mock.requests.isEmpty, "validation must fail before any request is issued")
    }

    @Test func postsResponseAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"customerReviewResponses","id":"resp-1"}}"#)

        let outcome = try await ReviewCommand.RespondReview.execute(
            client: mock, output: quietOutput(), reviewId: "rev-1", response: "Thanks!",
            dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "customerReviewResponses")
        let body = try jsonObject(requests[0].body)
        #expect(nested(body, "data", "attributes")["responseBody"] as? String == "Thanks!")
        #expect(
            nested(body, "data", "relationships", "review", "data")["id"] as? String == "rev-1")

        #expect(
            try #require(outcome).data
                == .object(["review_id": .string("rev-1"), "response_id": .string("resp-1")]))
    }
}

@Suite("Mutation envelope mappings") struct MutationOutcomeMappingTests {
    @Test func metadataPushSummaryMapsToStableKeys() {
        let outcome = MetadataCommand.Push.outcome(
            appId: "app-1", version: "2.0",
            summary: MetadataCommand.Push.Summary(
                pushed: ["en-US"], created: ["de-DE"], ignored: ["notes.md"]))

        #expect(
            outcome.data
                == .object([
                    "app_id": .string("app-1"),
                    "version": .string("2.0"),
                    "pushed_locales": .array([.string("en-US")]),
                    "created_locales": .array([.string("de-DE")]),
                    "ignored": .array([.string("notes.md")]),
                ]))
    }

    @Test func screenshotUploadSummaryMapsToStableKeys() {
        let outcome = ScreenshotsCommand.Upload.outcome(
            appId: "app-1", version: "2.0",
            summary: ScreenshotUploadService.Summary(
                uploadedCount: 3, localizationsCreated: ["fr-FR"], setsCreated: 1))

        #expect(
            outcome.data
                == .object([
                    "app_id": .string("app-1"),
                    "version": .string("2.0"),
                    "uploaded_count": .int(3),
                    "localizations_created": .array([.string("fr-FR")]),
                    "sets_created": .int(1),
                ]))
    }
}

@Suite("Versions create command") struct VersionsCreateCommandTests {
    private static let created = """
        {"data":{"type":"appStoreVersions","id":"ver-9","attributes":{"platform":"IOS",\
        "versionString":"3.1","appStoreState":"PREPARE_FOR_SUBMISSION","releaseType":"AFTER_APPROVAL"}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.Create.execute(
            client: mock, output: quietOutput(), appId: "app-1", version: "3.1",
            platform: "ios", releaseType: "manual", dryRun: true,
            nextActions: NextActions(propagatedFlags: []))

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func postsUppercasedAttributesAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.created)

        let outcome = try await VersionsCommand.Create.execute(
            client: mock, output: quietOutput(), appId: "app-1", version: "3.1",
            platform: "ios", releaseType: "manual", dryRun: false,
            nextActions: NextActions(propagatedFlags: []))

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "appStoreVersions")
        let body = try jsonObject(requests[0].body)
        let attrs = nested(body, "data", "attributes")
        #expect(attrs["platform"] as? String == "IOS")
        #expect(attrs["versionString"] as? String == "3.1")
        #expect(attrs["releaseType"] as? String == "MANUAL")
        let appRef = nested(body, "data", "relationships", "app", "data")
        #expect(appRef["id"] as? String == "app-1")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "id": .string("ver-9"),
                    "version": .string("3.1"),
                    "platform": .string("IOS"),
                    "state": .string("PREPARE_FOR_SUBMISSION"),
                ]))
        #expect(
            outcome?.next == ["submit": "appctl versions submit ver-9"],
            "a freshly created version is editable, so submit is offered")
    }
}

@Suite("Versions update command") struct VersionsUpdateCommandTests {
    private static let updated = """
        {"data":{"type":"appStoreVersions","id":"ver-1","attributes":{"platform":"IOS",\
        "versionString":"2.1","appStoreState":"PREPARE_FOR_SUBMISSION","releaseType":"MANUAL"}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.Update.execute(
            client: mock, output: quietOutput(), versionId: "ver-1",
            buildId: "build-1", version: "2.1", releaseType: nil, dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func attachesBuildThenPatchesAttributes() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.updated)

        let outcome = try await VersionsCommand.Update.execute(
            client: mock, output: quietOutput(), versionId: "ver-1",
            buildId: "build-1", version: "2.1", releaseType: "manual", dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "appStoreVersions/ver-1/relationships/build")
        let buildRef = nested(try jsonObject(requests[0].body), "data")
        #expect(buildRef["id"] as? String == "build-1")
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].path == "appStoreVersions/ver-1")
        let attrs = nested(try jsonObject(requests[1].body), "data", "attributes")
        #expect(attrs["releaseType"] as? String == "MANUAL")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "id": .string("ver-1"),
                    "attached_build_id": .string("build-1"),
                    "version": .string("2.1"),
                    "release_type": .string("MANUAL"),
                    "state": .string("PREPARE_FOR_SUBMISSION"),
                ]))
    }

    @Test func attachOnlySkipsAttributePatch() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.Update.execute(
            client: mock, output: quietOutput(), versionId: "ver-1",
            buildId: "build-1", version: nil, releaseType: nil, dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].path == "appStoreVersions/ver-1/relationships/build")
        #expect(
            try #require(outcome).data
                == .object(["id": .string("ver-1"), "attached_build_id": .string("build-1")]))
    }
}

@Suite("Versions phased-release command") struct VersionsPhasedReleaseCommandTests {
    private static let phasedRelease = """
        {"data":{"type":"appStoreVersionPhasedReleases","id":"phased-1"}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.PhasedRelease.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", action: "pause",
            dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil, "--dry-run produces no success envelope")
    }

    @Test func invalidActionFailsBeforeAnyRequest() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            _ = try await VersionsCommand.PhasedRelease.execute(
                client: mock, output: quietOutput(), versionId: "ver-1", action: "restart",
                dryRun: false)
        }
        #expect(await mock.requests.isEmpty, "validation must fail before any request is issued")
    }

    @Test func invalidActionFailsEvenUnderDryRun() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            _ = try await VersionsCommand.PhasedRelease.execute(
                client: mock, output: quietOutput(), versionId: "ver-1", action: "restart",
                dryRun: true)
        }
        #expect(await mock.requests.isEmpty)
    }

    @Test func resolvesPhasedReleaseThenPatchesState() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.phasedRelease)
        await mock.queue(Self.phasedRelease)

        let outcome = try await VersionsCommand.PhasedRelease.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", action: "pause",
            dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "appStoreVersions/ver-1/appStoreVersionPhasedRelease")
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].path == "appStoreVersionPhasedReleases/phased-1")
        let attrs = nested(try jsonObject(requests[1].body), "data", "attributes")
        #expect(attrs["phasedReleaseState"] as? String == "PAUSED")

        #expect(
            try #require(outcome).data
                == .object([
                    "id": .string("phased-1"),
                    "version_id": .string("ver-1"),
                    "state": .string("PAUSED"),
                ]))
    }

    @Test func missingPhasedReleaseThrowsResourceNotFound() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":null}"#)

        await #expect(throws: AppctlError.self) {
            _ = try await VersionsCommand.PhasedRelease.execute(
                client: mock, output: quietOutput(), versionId: "ver-1", action: "complete",
                dryRun: false)
        }
        #expect(await mock.requests.count == 1, "lookup only — no PATCH without a phased release")
    }
}

@Suite("Auth verify command") struct AuthVerifyCommandTests {
    @Test func returnsEnvelopeDataWithAppCount() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            """
            {"data":[{"type":"apps","id":"app-1","attributes":{"name":"My App"}}],\
            "meta":{"paging":{"total":42,"limit":1}}}
            """)

        let data = try await AuthCommand.Verify.execute(client: mock, output: quietOutput())

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "apps")
        let items = try #require(requests[0].queryItems)
        #expect(items.contains(URLQueryItem(name: "limit", value: "1")))

        #expect(data == .object(["authenticated": .bool(true), "app_count": .int(42)]))
    }

    @Test func zeroAppsIsStillAuthenticated() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":[],"meta":{"paging":{"total":0,"limit":1}}}"#)

        let data = try await AuthCommand.Verify.execute(client: mock, output: quietOutput())

        #expect(
            data == .object(["authenticated": .bool(true), "app_count": .int(0)]),
            "a brand-new account with no apps must still verify successfully")
    }
}

@Suite("Versions reject command") struct VersionsRejectCommandTests {
    private static let version = """
        {"data":{"type":"appStoreVersions","id":"ver-1","attributes":{"platform":"IOS","versionString":"2.0"}}}
        """
    private static let app = #"{"data":{"type":"apps","id":"app-1","attributes":{"name":"My App"}}}"#
    private static let openSubmission = """
        {"data":[{"type":"reviewSubmissions","id":"sub-1","attributes":{"platform":"IOS","state":"IN_REVIEW"}}]}
        """
    private static let canceled = """
        {"data":{"type":"reviewSubmissions","id":"sub-1","attributes":{"platform":"IOS","state":"CANCELING"}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await VersionsCommand.Reject.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func resolvesAppThenCancelsOpenSubmission() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.version)
        await mock.queue(Self.app)
        await mock.queue(Self.openSubmission)
        await mock.queue(Self.canceled)

        let outcome = try await VersionsCommand.Reject.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 4)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "PATCH"])
        #expect(requests[3].path == "reviewSubmissions/sub-1")
        let attrs = nested(try jsonObject(requests[3].body), "data", "attributes")
        #expect(attrs["canceled"] as? Bool == true)

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "version_id": .string("ver-1"),
                    "submission_id": .string("sub-1"),
                    "submission_state": .string("CANCELING"),
                ]))
    }
}
