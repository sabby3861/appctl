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

        let outcome = try await WorkflowCommand.Release.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
            buildId: "123456", platform: "IOS", releaseType: "AFTER_APPROVAL",
            phased: false, dryRun: false, skipSubmit: true, legacySubmit: false,
            nextActions: NextActions(propagatedFlags: []))

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "app_id": .string("app-1"),
                    "version": .string("2.0"),
                    "version_id": .string("ver-1"),
                    "build_id": .string("123456"),
                    "build_version": .string("1.2.3"),
                    "submitted": .bool(false),
                ]))
        #expect(
            outcome?.next == ["submit": "appctl versions submit ver-1"],
            "--skip-submit leaves submission as the obvious next step")

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
            _ = try await WorkflowCommand.Release.execute(
                client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
                buildId: "999999", platform: "IOS", releaseType: "AFTER_APPROVAL",
                phased: false, dryRun: false, skipSubmit: true, legacySubmit: false,
                nextActions: NextActions(propagatedFlags: []))
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

        let outcome = try await WorkflowCommand.Release.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
            buildId: "123456", platform: "IOS", releaseType: "AFTER_APPROVAL",
            phased: false, dryRun: true, skipSubmit: false, legacySubmit: false,
            nextActions: NextActions(propagatedFlags: []))

        #expect(outcome == nil, "--dry-run produces no success envelope")
        let requests = await mock.requests
        try #require(requests.count == 1, "dry run must validate the id and do nothing else")
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "builds/123456")
    }

    @Test func submittedReleaseOffersRejectAsNext() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.build123456)
        await mock.queue(Self.createdVersion)
        await mock.queue(#"{"data":[]}"#)
        await mock.queue(
            #"{"data":{"type":"reviewSubmissions","id":"sub-1","attributes":{"state":"READY_FOR_REVIEW"}}}"#)
        await mock.queue(#"{"data":{"type":"reviewSubmissionItems","id":"item-1"}}"#)
        await mock.queue(
            #"{"data":{"type":"reviewSubmissions","id":"sub-1","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#)

        let outcome = try await WorkflowCommand.Release.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", version: "2.0",
            buildId: "123456", platform: "IOS", releaseType: "AFTER_APPROVAL",
            phased: false, dryRun: false, skipSubmit: false, legacySubmit: false,
            nextActions: NextActions(propagatedFlags: []))

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "app_id": .string("app-1"),
                    "version": .string("2.0"),
                    "version_id": .string("ver-1"),
                    "build_id": .string("123456"),
                    "build_version": .string("1.2.3"),
                    "submitted": .bool(true),
                ]))
        #expect(outcome?.next == ["reject": "appctl versions reject ver-1"])
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

@Suite("Workflow publish") struct WorkflowPublishTests {
    private static let declaredBuild = """
        {"data":[{"type":"builds","id":"build-1","attributes":{"version":"7","processingState":"VALID",\
        "expired":false,"usesNonExemptEncryption":false}}]}
        """
    private static let undeclaredBuild = """
        {"data":[{"type":"builds","id":"build-1","attributes":{"version":"7","processingState":"VALID",\
        "expired":false}}]}
        """
    private static let patchedBuild = """
        {"data":{"type":"builds","id":"build-1","attributes":{"version":"7","processingState":"VALID",\
        "expired":false,"usesNonExemptEncryption":false}}}
        """
    private static let groups = """
        {"data":[{"type":"betaGroups","id":"group-ext","attributes":{"name":"Beta","isInternalGroup":false}},\
        {"type":"betaGroups","id":"group-int","attributes":{"name":"Team","isInternalGroup":true}}]}
        """

    private static func quietOutput() -> OutputFormatter {
        OutputFormatter(format: .json, noColor: true)
    }

    @Test func distributesLatestBuildToExplicitGroup() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.declaredBuild)

        let outcome = try await WorkflowCommand.Publish.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", groupId: "group-1",
            internalGroup: false, externalGroup: false, dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "builds")
        #expect(
            requests[0].queryItems?.contains(
                URLQueryItem(name: "filter[processingState]", value: "VALID")) == true)
        #expect(requests[1].method == "POST")
        #expect(requests[1].path == "betaGroups/group-1/relationships/builds")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "app_id": .string("app-1"),
                    "build_id": .string("build-1"),
                    "build_version": .string("7"),
                    "group_id": .string("group-1"),
                ]))
    }

    @Test func autoSelectsInternalGroupAndDeclaresMissingCompliance() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.undeclaredBuild)
        await mock.queue(Self.patchedBuild)
        await mock.queue(Self.groups)

        let outcome = try await WorkflowCommand.Publish.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", groupId: nil,
            internalGroup: true, externalGroup: false, dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 4)
        #expect(requests.map(\.method) == ["GET", "PATCH", "GET", "POST"])
        #expect(requests[1].path == "builds/build-1", "undeclared compliance is set to exempt first")
        #expect(requests[2].path == "betaGroups")
        #expect(requests[3].path == "betaGroups/group-int/relationships/builds")
        #expect(
            try #require(outcome).data
                == .object([
                    "app_id": .string("app-1"),
                    "build_id": .string("build-1"),
                    "build_version": .string("7"),
                    "group_id": .string("group-int"),
                ]))
    }

    @Test func dryRunFindsTargetsButDistributesNothing() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.undeclaredBuild)

        let outcome = try await WorkflowCommand.Publish.execute(
            client: mock, output: Self.quietOutput(), appId: "app-1", groupId: "group-1",
            internalGroup: false, externalGroup: false, dryRun: true)

        let requests = await mock.requests
        #expect(
            requests.map(\.method) == ["GET"],
            "--dry-run must not declare compliance or distribute")
        #expect(outcome == nil)
    }
}
