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

        try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: true, legacySubmit: false)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
    }

    @Test func newFlowResolvesAppThenDrivesReviewSubmission() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.version)
        await mock.queue(Self.app)
        await mock.queue(Self.noOpenSubmissions)
        await mock.queue(Self.submission)
        await mock.queue(Self.submissionItem)
        await mock.queue(Self.submission)

        try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false, legacySubmit: false)

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
    }

    @Test func legacyFlagPostsDeprecatedSubmissionEndpoint() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appStoreVersionSubmissions","id":"legacy-1"}}"#)

        try await VersionsCommand.Submit.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false, legacySubmit: true)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "appStoreVersionSubmissions")
        let ref = nested(try jsonObject(requests[0].body), "data", "relationships", "appStoreVersion", "data")
        #expect(ref["id"] as? String == "ver-1")
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
                client: mock, output: quietOutput(), versionId: "ver-1", dryRun: false, legacySubmit: false)
        }
    }
}
