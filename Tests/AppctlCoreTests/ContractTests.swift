import Crypto
import Foundation
import Testing

@testable import AppctlCore

// Acceptance tests for the agent-facing output contract: the envelope with
// state-aware next actions, the stable error taxonomy with exit classes, the
// --query evaluator, the early argv scan, and the retry policy end to end.

@Suite("Envelope next actions") struct NextActionsTests {
    private func versionsJSON(state: String, id: String = "v-123") -> String {
        """
        {"data":[{"type":"appStoreVersions","id":"\(id)",
          "attributes":{"versionString":"1.0","appStoreState":"\(state)","platform":"IOS"}}]}
        """
    }

    @Test func editableVersionOffersSubmit() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(versionsJSON(state: "PREPARE_FOR_SUBMISSION"))
        let (versions, next) = try await VersionsCommand.List.execute(
            client: mock, appId: "6448311069", platform: nil,
            nextActions: NextActions(propagatedFlags: []))
        #expect(versions.count == 1)
        #expect(next["submit"] == "appctl versions submit v-123")
        #expect(next["reject"] == nil)
    }

    @Test func lockedVersionOffersNoSubmit() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(versionsJSON(state: "READY_FOR_SALE"))
        let (_, next) = try await VersionsCommand.List.execute(
            client: mock, appId: "6448311069", platform: nil,
            nextActions: NextActions(propagatedFlags: []))
        #expect(next.isEmpty, "a locked version offers no actions")
    }

    @Test func inReviewVersionOffersRejectOnly() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(versionsJSON(state: "WAITING_FOR_REVIEW"))
        let (_, next) = try await VersionsCommand.List.execute(
            client: mock, appId: "6448311069", platform: nil,
            nextActions: NextActions(propagatedFlags: []))
        #expect(next["reject"] == "appctl versions reject v-123")
        #expect(next["submit"] == nil)
    }

    @Test func propagatedFlagsRideAlongVerbatim() {
        let actions = NextActions(propagatedFlags: ["--key-id", "ABC123", "--output", "json"])
        #expect(
            actions.forVersions([(id: "v-9", state: "DEVELOPER_REJECTED")])["submit"]
                == "appctl versions submit v-9 --key-id ABC123 --output json")
    }

    @Test func unsafeTokensAreShellQuoted() {
        let actions = NextActions(propagatedFlags: [])
        #expect(
            actions.nextPage(url: "https://api.appstoreconnect.apple.com/v1/apps?cursor=a&limit=5")
                == ["nextPage": "appctl api GET 'https://api.appstoreconnect.apple.com/v1/apps?cursor=a&limit=5'"])
    }

    @Test func failureEnvelopeCarriesCodeAndExitClass() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(Envelope.failure(.rateLimited(retryAfter: 30)))
        let object = try jsonObject(data)
        #expect(object["data"] is NSNull)
        let error = nested(object, "error")
        #expect(error["code"] as? String == "API_RATE_LIMITED")
        #expect(error["exitClass"] as? Int == 3)
        #expect((error["docs"] as? String)?.hasSuffix("#api_rate_limited") == true)
    }
}

@Suite("Error taxonomy") struct ErrorTaxonomyTests {
    @Test func everyCaseMapsToTheExpectedClass() {
        let expectations: [(AppctlError, ErrorCode, Int32)] = [
            (.missingAPIKey(detail: "x"), .authMissingKey, 4),
            (.agreementPending(detail: "x"), .authAgreementPending, 4),
            (.unauthorized(endpoint: "/v1/apps"), .authUnauthorized, 4),
            (.invalidInput(field: "--x", value: "y", expected: "z"), .usageInvalidArgument, 1),
            (.confirmationRequired(operation: "DELETE"), .usageConfirmationRequired, 1),
            (.charLimitExceeded(field: "keywords", limit: 100, actual: 120), .validationCharLimit, 2),
            (.rateLimited(retryAfter: 5), .apiRateLimited, 3),
            (.resourceNotFound(type: "Build", identifier: "1"), .apiNotFound, 3),
            (.timeout(url: "u", duration: 30), .networkTimeout, 5),
            (.connectionFailed(host: "h", reason: "r"), .networkConnectionFailed, 5),
            (.uploadPartFailed(partNumber: 1, attempts: 3, reason: "r"), .uploadPartFailed, 5),
        ]
        for (error, code, exitClass) in expectations {
            #expect(error.errorCode == code)
            #expect(error.errorCode.exitClass == exitClass)
        }
    }

    @Test func stateErrorRefinesToResourceLocked() {
        let error = AppctlError.apiError(
            operation: "POST /v1/reviewSubmissions", statusCode: 409,
            errors: [
                APIErrorDetail(
                    id: nil, status: "409", code: "STATE_ERROR.ENTITY_STATE_INVALID",
                    title: "Invalid state", detail: "already in review", source: nil)
            ])
        #expect(error.errorCode == .apiResourceLocked)
        #expect(error.errorCode.exitClass == 3)
    }

    @Test func forbiddenAgreementRefinesToAuthClass() {
        let error = AppctlError.apiError(
            operation: "GET /v1/apps", statusCode: 403,
            errors: [
                APIErrorDetail(
                    id: nil, status: "403", code: "FORBIDDEN_ERROR",
                    title: "Access forbidden",
                    detail: "A required agreement is missing or has expired.", source: nil)
            ])
        #expect(error.errorCode == .authAgreementPending)
        #expect(error.errorCode.exitClass == 4)
    }

    @Test func diagnosticMessageCarriesTheCodeLine() {
        let message = AppctlError.missingAPIKey(detail: "x").diagnosticMessage
        #expect(message.contains("Code: AUTH_MISSING_KEY"))
        #expect(message.contains("docs/errors.md#auth_missing_key"))
    }

    @Test func everyCodeHasAUniqueRawValueAndDocsAnchor() {
        let raws = ErrorCode.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for code in ErrorCode.allCases {
            #expect(code.docsURL.hasSuffix("#\(code.rawValue.lowercased())"))
            #expect((1...5).contains(code.exitClass))
        }
    }

    @Test func metadataCharLimitPathThrowsTheTaxonomyCode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-charlimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try String(repeating: "k", count: 101)
            .write(to: locale.appendingPathComponent("keywords.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try MetadataCommand.Push.scan(directory: dir)
            Issue.record("expected charLimitExceeded")
        } catch let error as AppctlError {
            #expect(error.errorCode == .validationCharLimit)
            #expect(error.errorCode.exitClass == 2)
        }
    }

    @Test func yesIsRefusedByTheAPIDeleteGate() async throws {
        var command = try APICommand.parse(["DELETE", "/v1/betaGroups/G1", "--yes", "--confirm"])
        do {
            try await command.run()
            Issue.record("expected --yes to be refused")
        } catch let error as AppctlError {
            #expect(error.errorCode == .usageInvalidArgument)
            #expect(error.diagnosticMessage.contains("--confirm"))
        }
    }
}

@Suite("Query evaluator") struct QueryEvaluatorTests {
    private let versions: JSONValue = .array([
        .object(["id": .string("v-1"), "state": .string("READY_FOR_SALE"), "build": .int(41)]),
        .object(["id": .string("v-2"), "state": .string("PREPARE_FOR_SUBMISSION"), "build": .int(42)]),
        .object(["id": .string("v-3"), "state": .string("PREPARE_FOR_SUBMISSION"), "build": .int(43)]),
    ])

    @Test func filterProjectsMatchingElements() throws {
        let result = try QueryEvaluator(parsing: "[?state=='PREPARE_FOR_SUBMISSION'].id")
            .evaluate(versions)
        #expect(result == .array([.string("v-2"), .string("v-3")]))
    }

    @Test func negatedFilter() throws {
        let result = try QueryEvaluator(parsing: "[?state!='READY_FOR_SALE'].id").evaluate(versions)
        #expect(result == .array([.string("v-2"), .string("v-3")]))
    }

    @Test func numericFilterCoercesIntAndDouble() throws {
        let result = try QueryEvaluator(parsing: "[?build==42].id").evaluate(versions)
        #expect(result == .array([.string("v-2")]))
    }

    @Test func wildcardProjection() throws {
        let result = try QueryEvaluator(parsing: "[*].id").evaluate(versions)
        #expect(result == .array([.string("v-1"), .string("v-2"), .string("v-3")]))
    }

    @Test func dotPathAndIndex() throws {
        let doc: JSONValue = .object(["data": versions])
        #expect(
            try QueryEvaluator(parsing: "data[0].id").evaluate(doc) == .string("v-1"))
        #expect(
            try QueryEvaluator(parsing: "data[-1].id").evaluate(doc) == .string("v-3"))
    }

    @Test func missingPathsYieldNullNotErrors() throws {
        #expect(try QueryEvaluator(parsing: "nope.nested").evaluate(versions) == .null)
        #expect(try QueryEvaluator(parsing: "[*].missing").evaluate(versions) == .array([]))
    }

    @Test func projectionDropsNullResults() throws {
        let mixed: JSONValue = .array([
            .object(["id": .string("a")]), .object(["other": .string("x")]),
        ])
        #expect(try QueryEvaluator(parsing: "[*].id").evaluate(mixed) == .array([.string("a")]))
    }

    @Test func syntaxErrorsAreUsageErrors() {
        for bad in ["", "items[", "items[?]", "items[?x>3]", "items[?x=='unterminated]", "a..b"] {
            do {
                _ = try QueryEvaluator(parsing: bad)
                Issue.record("expected parse failure for \(bad)")
            } catch let error as AppctlError {
                #expect(error.errorCode == .usageInvalidArgument)
            } catch {
                Issue.record("unexpected error type for \(bad)")
            }
        }
    }
}

@Suite("Early output-mode argv scan") struct EarlyOutputModeTests {
    @Test func detectsSpaceAndEqualsForms() {
        #expect(FailureRenderer.earlyOutputMode(from: ["apps", "list", "--output", "json"]) == .json)
        #expect(FailureRenderer.earlyOutputMode(from: ["apps", "list", "--output=json"]) == .json)
        #expect(FailureRenderer.earlyOutputMode(from: ["apps", "list", "--format", "json"]) == .json)
        #expect(FailureRenderer.earlyOutputMode(from: ["apps", "list", "--format=json"]) == .json)
    }

    @Test func absenceAndUnknownValuesYieldNoMode() {
        #expect(FailureRenderer.earlyOutputMode(from: ["apps", "list"]) == nil)
        #expect(FailureRenderer.earlyOutputMode(from: ["--output", "bogus"]) == nil)
        #expect(FailureRenderer.earlyOutputMode(from: ["--output"]) == nil)
    }

    @Test func lastOccurrenceWins() {
        #expect(
            FailureRenderer.earlyOutputMode(from: ["--output", "json", "--output", "table"]) == .table)
        #expect(
            FailureRenderer.earlyOutputMode(from: ["--format", "csv", "--output=json"]) == .json)
    }

    @Test func tokensAfterTerminatorAreIgnored() {
        #expect(FailureRenderer.earlyOutputMode(from: ["run", "--", "--output", "json"]) == nil)
    }

    @Test func failureEnvelopeFollowsTheSuccessPathResolution() {
        let tty = { true }
        let noTTY = { false }
        let ci = { true }
        let noCI = { false }
        // Explicit flag wins in both directions, regardless of environment.
        #expect(
            FailureRenderer.wantsJSONEnvelope(
                arguments: ["--output", "json"], isTerminal: tty, isCI: noCI))
        #expect(
            !FailureRenderer.wantsJSONEnvelope(
                arguments: ["--output", "table"], isTerminal: noTTY, isCI: ci))
        // --query implies JSON.
        #expect(
            FailureRenderer.wantsJSONEnvelope(
                arguments: ["--query", "data.id"], isTerminal: tty, isCI: noCI))
        // No flag: piped or CI output defaults to JSON, interactive to text.
        #expect(FailureRenderer.wantsJSONEnvelope(arguments: [], isTerminal: noTTY, isCI: noCI))
        #expect(FailureRenderer.wantsJSONEnvelope(arguments: [], isTerminal: tty, isCI: ci))
        #expect(!FailureRenderer.wantsJSONEnvelope(arguments: [], isTerminal: tty, isCI: noCI))
    }
}

@Suite("APIClient retry over a scripted transport") struct TransportRetryTests {
    /// Replays a fixed sequence of (status, body, headers) responses.
    actor ScriptedTransport: HTTPTransport {
        struct Response {
            let status: Int
            let body: String
            let headers: [String: String]
        }
        private var responses: [Response]
        private(set) var requestCount = 0

        init(_ responses: [Response]) { self.responses = responses }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requestCount += 1
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }
            let next = responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"), statusCode: next.status,
                httpVersion: "HTTP/1.1", headerFields: next.headers)
            guard let http else { throw URLError(.badServerResponse) }
            return (Data(next.body.utf8), http)
        }
    }

    private func client(over transport: ScriptedTransport) throws -> APIClient {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let generator = try JWTGenerator(keyID: "TEST", issuerID: "issuer-1", privateKeyPEM: pem)
        return APIClient(jwtGenerator: generator, transport: transport, retryBaseDelay: 0.001)
    }

    @Test func rateLimitedThenSucceeds() async throws {
        // Two 429s (Retry-After: 0 keeps the test instant), then a 200 — within
        // the 5-attempt rate-limit budget, so the call must succeed.
        let transport = ScriptedTransport([
            .init(status: 429, body: "", headers: ["Retry-After": "0"]),
            .init(status: 429, body: "", headers: ["Retry-After": "0"]),
            .init(status: 200, body: #"{"data":{"type":"apps","id":"1"}}"#, headers: [:]),
        ])
        let document: JSONValue = try await client(over: transport).get("apps/1")
        #expect(document["data"]?["id"] == .string("1"))
        #expect(await transport.requestCount == 3)
    }

    @Test func rateLimitBudgetExhaustsWithTheTaxonomyCode() async throws {
        let responses = Array(
            repeating: ScriptedTransport.Response(
                status: 429, body: "", headers: ["Retry-After": "0"]),
            count: 6)
        let transport = ScriptedTransport(responses)
        do {
            let _: JSONValue = try await client(over: transport).get("apps/1")
            Issue.record("expected rateLimited after the budget")
        } catch let error as AppctlError {
            #expect(error.errorCode == .apiRateLimited)
            #expect(error.errorCode.exitClass == 3)
        }
        #expect(await transport.requestCount == RetryStrategy.rateLimited.maxAttempts)
    }

    @Test func serverErrorsRetryThreeTimesThenSurface() async throws {
        let transport = ScriptedTransport([
            .init(status: 503, body: "", headers: [:]),
            .init(status: 503, body: "", headers: [:]),
            .init(status: 503, body: "", headers: [:]),
        ])
        do {
            let _: JSONValue = try await client(over: transport).get("apps/1")
            Issue.record("expected requestFailed after 3 attempts")
        } catch let error as AppctlError {
            #expect(error.errorCode == .apiRequestFailed)
        }
        #expect(await transport.requestCount == RetryStrategy.serverError.maxAttempts)
    }
}
