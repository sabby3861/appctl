import Foundation
import Testing

@testable import AppctlCore

@Suite("Workflow release --build-id") struct WorkflowReleaseBuildIDTests {
    /// The build number is deliberately distinct from the resource id: under the old
    /// behavior (`buildVersion = explicit`) these tests would still pass if both were
    /// "123456".
    private static let build123456 =
        "{\"data\":{\"type\":\"builds\",\"id\":\"123456\",\"attributes\":{\"version\":\"1.2.3\",\"processingState\":\"VALID\"}}}"
    private static let createdVersion =
        "{\"data\":{\"type\":\"appStoreVersions\",\"id\":\"ver-1\",\"attributes\":{\"versionString\":\"2.0\"}}}"
    private static let notFoundBody =
        "{\"errors\":[{\"status\":\"404\",\"code\":\"NOT_FOUND\",\"title\":\"The specified resource does not exist.\",\"detail\":\"There is no resource of type 'builds' with id '999999'.\"}]}"

    private static func quietOutput() -> OutputFormatter {
        OutputFormatter(format: .json, noColor: true)
    }

    @Test func explicitBuildIdResolvesDisplayVersionFromFetchedAttributes() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            "{\"data\":{\"type\":\"builds\",\"id\":\"123456\",\"attributes\":{\"version\":\"1.2.3\",\"processingState\":\"PROCESSING\"}}}"
        )

        let resolved = try await WorkflowCommand.Release.resolveExplicitBuild(
            client: mock, buildId: "123456")
        #expect(resolved.id == "123456", "the relationship must target the resource id, never the build number")
        #expect(resolved.displayVersion == "1.2.3", "humans must see attributes.version, not the raw id")
        #expect(resolved.processingState == "PROCESSING")

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "builds/123456")
    }

    @Test func explicitBuildIdTargetsRelationshipWithIdAndDisplaysFetchedVersion() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.build123456)
        await mock.queue(Self.createdVersion)

        try await WorkflowCommand.Release.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
            buildId: "123456", platform: "IOS", releaseType: "AFTER_APPROVAL",
            phased: false, dryRun: false, skipSubmit: true, legacySubmit: false)

        let requests = await mock.requests
        let validation = try #require(requests.first)
        #expect(validation.method == "GET")
        #expect(validation.path == "builds/123456", "the id must be validated before the pipeline starts")

        let attach = try #require(requests.last)
        #expect(attach.method == "PATCH")
        #expect(attach.path == "appStoreVersions/ver-1/relationships/build")
        let body = try jsonObject(attach.body)
        let ref = nested(body, "data")
        #expect(ref["type"] as? String == "builds")
        #expect(ref["id"] as? String == "123456", "the relationship must target the raw builds resource id")
    }

    @Test func nonexistentBuildIdFailsFastWithFixLineBeforeAnyMutation() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.failNext("GET", "builds/999999", withErrorBody: Self.notFoundBody)

        do {
            try await WorkflowCommand.Release.execute(
                client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
                buildId: "999999", platform: "IOS", releaseType: "AFTER_APPROVAL",
                phased: false, dryRun: false, skipSubmit: true, legacySubmit: false)
            Issue.record("A nonexistent --build-id must throw before the pipeline starts")
        } catch let error as AppctlError {
            guard case .resourceNotFound(let type, let identifier) = error else {
                Issue.record("Expected resourceNotFound, got \(error)")
                return
            }
            #expect(type == "Build")
            #expect(identifier == "999999")
            #expect(error.diagnosticMessage.contains("Fix:"), "a bad --build-id must carry an actionable Fix line")
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }

        let requests = await mock.requests
        #expect(
            requests.allSatisfy { $0.method == "GET" },
            "nothing may be created or mutated when validation fails")
        #expect(requests.count == 1, "validation must fail fast, without retries or further calls")
    }

    @Test func dryRunStillValidatesExplicitBuildIdButMutatesNothing() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.build123456)

        try await WorkflowCommand.Release.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
            buildId: "123456", platform: "IOS", releaseType: "AFTER_APPROVAL",
            phased: false, dryRun: true, skipSubmit: false, legacySubmit: false)

        let requests = await mock.requests
        try #require(requests.count == 1, "dry run must validate the id and do nothing else")
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "builds/123456")
    }

    @Test func non404ErrorsDuringValidationSurfaceVerbatim() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.failNext(
            "GET", "builds/123456",
            withErrorBody:
                "{\"errors\":[{\"status\":\"403\",\"code\":\"FORBIDDEN_ERROR\",\"title\":\"This request is forbidden for security reasons.\",\"detail\":\"The API key does not have sufficient permissions.\"}]}"
        )

        do {
            _ = try await WorkflowCommand.Release.resolveExplicitBuild(client: mock, buildId: "123456")
            Issue.record("A forbidden validation fetch must throw")
        } catch let error as AppctlError {
            guard case .apiError(_, let statusCode, _) = error else {
                Issue.record("Only 404 may be remapped; expected apiError, got \(error)")
                return
            }
            #expect(statusCode == 403)
            #expect(error.diagnosticMessage.contains("The API key does not have sufficient permissions."))
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }
    }
}
