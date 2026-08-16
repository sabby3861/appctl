import Foundation
import Testing

@testable import AppctlCore

/// Records every request and replays canned JSON responses in FIFO order. Error
/// injection mirrors `APIClient`: the queued JSON:API error body is decoded and
/// surfaced as `AppctlError.apiError`, exactly as a real non-2xx response would be.
///
/// The mock itself is a nonisolated struct with its mutable state in an inner actor:
/// bodies are encoded to `Data` before entering the actor and responses decoded after
/// leaving it, so the client protocol's non-Sendable generic results never cross an
/// isolation boundary.
struct MockAppStoreConnectClient: AppStoreConnectClient {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [URLQueryItem]?
        let body: Data?
    }

    actor Storage {
        private(set) var requests: [RecordedRequest] = []
        private var responses: [Data] = []
        private var errorBodies: [String: Data] = [:]

        func queue(_ json: String) { responses.append(Data(json.utf8)) }

        func failNext(_ method: String, _ path: String, withErrorBody json: String) {
            errorBodies["\(method) \(path)"] = Data(json.utf8)
        }

        func record(_ method: String, _ path: String, queryItems: [URLQueryItem]?, body: Data?) throws {
            requests.append(RecordedRequest(method: method, path: path, queryItems: queryItems, body: body))
            if let errData = errorBodies.removeValue(forKey: "\(method) \(path)") {
                let decoded = try JSONDecoder().decode(APIErrorResponse.self, from: errData)
                guard let first = decoded.errors.first else {
                    throw AppctlError.invalidResponse(url: path, reason: "Mock error body has no errors.")
                }
                throw AppctlError.apiError(
                    operation: "\(method) /v1/\(path)",
                    statusCode: Int(first.status) ?? 0,
                    errors: decoded.errors)
            }
        }

        func nextResponse() throws -> Data {
            guard !responses.isEmpty else {
                throw AppctlError.invalidResponse(url: "mock", reason: "No queued response.")
            }
            return responses.removeFirst()
        }
    }

    private let storage = Storage()

    var requests: [RecordedRequest] {
        get async { await storage.requests }
    }

    func queue(_ json: String) async { await storage.queue(json) }

    func failNext(_ method: String, _ path: String, withErrorBody json: String) async {
        await storage.failNext(method, path, withErrorBody: json)
    }

    private func perform<T: Decodable>(
        _ method: String, _ path: String, queryItems: [URLQueryItem]? = nil,
        body: (Encodable & Sendable)? = nil
    ) async throws -> T {
        try await record(method, path, queryItems: queryItems, body: body)
        let data = try await storage.nextResponse()
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func record(
        _ method: String, _ path: String, queryItems: [URLQueryItem]? = nil,
        body: (Encodable & Sendable)? = nil
    ) async throws {
        let bodyData = try body.map { try JSONEncoder().encode(EncodableBox($0)) }
        try await storage.record(method, path, queryItems: queryItems, body: bodyData)
    }

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]?) async throws -> T {
        try await perform("GET", path, queryItems: queryItems)
    }

    func getList<T: Decodable>(
        _ path: String, queryItems: [URLQueryItem]?, limit: Int
    ) async throws -> APIListResponse<T> {
        try await perform("GET", path, queryItems: queryItems)
    }

    func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        try await perform("POST", path, body: body)
    }

    func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        try await perform("PATCH", path, body: body)
    }

    func delete(_ path: String) async throws {
        try await record("DELETE", path)
    }

    func postVoid(_ path: String, body: Encodable & Sendable) async throws {
        try await record("POST", path, body: body)
    }

    func patchVoid(_ path: String, body: Encodable & Sendable) async throws {
        try await record("PATCH", path, body: body)
    }
}

private struct EncodableBox: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}

private func jsonObject(_ data: Data?) throws -> [String: Any] {
    let d = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
}

private func nested(_ dict: [String: Any], _ keys: String...) -> [String: Any] {
    var current = dict
    for key in keys {
        guard let next = current[key] as? [String: Any] else { return [:] }
        current = next
    }
    return current
}

@Suite("Review submission flow") struct ReviewSubmissionServiceTests {
    private static let emptyList = "{\"data\":[]}"
    private static let createdSubmission =
        "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-1\"}}"
    private static let createdItem =
        "{\"data\":{\"type\":\"reviewSubmissionItems\",\"id\":\"item-1\"}}"
    private static let submittedSubmission =
        "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-1\",\"attributes\":{\"state\":\"WAITING_FOR_REVIEW\"}}}"

    @Test func submitPerformsThreeStepsInOrderWithCorrectBodies() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await mock.queue(Self.createdSubmission)
        await mock.queue(Self.createdItem)
        await mock.queue(Self.submittedSubmission)

        let result = try await ReviewSubmissionService(client: mock)
            .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
        #expect(result.reused == false)
        #expect(result.submission.id == "rs-1")

        let requests = await mock.requests
        let lookup = try #require(requests.first)
        #expect(lookup.method == "GET")
        #expect(lookup.path == "apps/app-1/reviewSubmissions")
        #expect(
            lookup.queryItems?.contains(URLQueryItem(name: "filter[state]", value: "READY_FOR_REVIEW"))
                == true)
        #expect(
            lookup.queryItems?.contains(URLQueryItem(name: "filter[platform]", value: "IOS")) == true)

        let mutating = requests.filter { $0.method != "GET" }
        try #require(mutating.count == 3)
        #expect(
            mutating.map { "\($0.method) \($0.path)" } == [
                "POST reviewSubmissions",
                "POST reviewSubmissionItems",
                "PATCH reviewSubmissions/rs-1",
            ])

        let create = try jsonObject(mutating[0].body)
        #expect(nested(create, "data")["type"] as? String == "reviewSubmissions")
        #expect(nested(create, "data", "attributes")["platform"] as? String == "IOS")
        let appRef = nested(create, "data", "relationships", "app", "data")
        #expect(appRef["type"] as? String == "apps")
        #expect(appRef["id"] as? String == "app-1")

        let item = try jsonObject(mutating[1].body)
        #expect(nested(item, "data")["type"] as? String == "reviewSubmissionItems")
        let submissionRef = nested(item, "data", "relationships", "reviewSubmission", "data")
        #expect(submissionRef["type"] as? String == "reviewSubmissions")
        #expect(submissionRef["id"] as? String == "rs-1")
        let versionRef = nested(item, "data", "relationships", "appStoreVersion", "data")
        #expect(versionRef["type"] as? String == "appStoreVersions")
        #expect(versionRef["id"] as? String == "ver-1")

        let update = try jsonObject(mutating[2].body)
        #expect(nested(update, "data")["type"] as? String == "reviewSubmissions")
        #expect(nested(update, "data")["id"] as? String == "rs-1")
        let updateAttributes = nested(update, "data", "attributes")
        #expect(updateAttributes["submitted"] as? Bool == true)
        #expect(updateAttributes["canceled"] == nil, "canceled must be omitted when submitting")
    }

    @Test func submitReusesOpenReadyForReviewSubmission() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            "{\"data\":[{\"type\":\"reviewSubmissions\",\"id\":\"rs-9\",\"attributes\":{\"state\":\"READY_FOR_REVIEW\",\"platform\":\"IOS\"}}]}"
        )
        await mock.queue("{\"data\":{\"type\":\"reviewSubmissionItems\",\"id\":\"item-2\"}}")
        await mock.queue(
            "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-9\",\"attributes\":{\"state\":\"WAITING_FOR_REVIEW\"}}}"
        )

        let result = try await ReviewSubmissionService(client: mock)
            .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
        #expect(result.reused == true)
        #expect(result.submission.id == "rs-9")

        let mutating = await mock.requests.filter { $0.method != "GET" }
        #expect(
            mutating.map { "\($0.method) \($0.path)" } == [
                "POST reviewSubmissionItems",
                "PATCH reviewSubmissions/rs-9",
            ], "an open submission must be reused, never re-created")
    }

    @Test func submitFollowsPaginationWhenSearchingForReusableSubmission() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            "{\"data\":[],\"links\":{\"next\":\"https://api.appstoreconnect.apple.com/v1/apps/app-1/reviewSubmissions?cursor=x\"}}"
        )
        await mock.queue(
            "{\"data\":[{\"type\":\"reviewSubmissions\",\"id\":\"rs-2\",\"attributes\":{\"state\":\"READY_FOR_REVIEW\"}}]}"
        )
        await mock.queue(Self.createdItem)
        await mock.queue(
            "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-2\",\"attributes\":{\"state\":\"WAITING_FOR_REVIEW\"}}}"
        )

        let result = try await ReviewSubmissionService(client: mock)
            .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
        #expect(result.reused == true)
        #expect(result.submission.id == "rs-2")

        let gets = await mock.requests.filter { $0.method == "GET" }
        #expect(gets.count == 2, "must follow links.next when scanning for reusable submissions")
    }

    @Test func conflictSurfacesAppleErrorDetailVerbatim() async throws {
        let detail = "The app is missing required metadata: privacy policy URL."
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await mock.queue(Self.createdSubmission)
        await mock.failNext(
            "POST", "reviewSubmissionItems",
            withErrorBody:
                "{\"errors\":[{\"status\":\"409\",\"code\":\"STATE_ERROR\",\"title\":\"The request cannot be fulfilled.\",\"detail\":\"\(detail)\"}]}"
        )

        do {
            _ = try await ReviewSubmissionService(client: mock)
                .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
            Issue.record("A 409 conflict must throw so the command exits non-zero")
        } catch let error as AppctlError {
            #expect(error.diagnosticMessage.contains(detail), "Apple's errors[].detail must surface verbatim")
            #expect(error.diagnosticMessage.contains("HTTP 409"), "the What line must carry the HTTP status")
            #expect(
                error.diagnosticMessage.contains("POST /v1/reviewSubmissionItems"),
                "the What line must carry the failed operation")
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }

        let mutating = await mock.requests.filter { $0.method != "GET" }
        #expect(
            mutating.map { "\($0.method) \($0.path)" } == [
                "POST reviewSubmissions",
                "POST reviewSubmissionItems",
            ], "the flow must stop at the failed step")
    }

    @Test func multipleAppleErrorsAllSurfaceVerbatim() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await mock.queue(Self.createdSubmission)
        await mock.failNext(
            "POST", "reviewSubmissionItems",
            withErrorBody: """
                {"errors":[\
                {"status":"409","code":"STATE_ERROR.SCREENSHOT_REQUIRED","title":"App screenshots are required.","detail":"Provide at least one screenshot for the 6.7-inch display."},\
                {"status":"409","code":"STATE_ERROR.PRIVACY_POLICY","title":"A privacy policy URL is required.","detail":"Set a privacy policy URL for this version."}\
                ]}
                """
        )

        do {
            _ = try await ReviewSubmissionService(client: mock)
                .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
            Issue.record("The failed submission must throw so the command exits non-zero")
        } catch let error as AppctlError {
            let message = error.diagnosticMessage
            #expect(message.contains("App screenshots are required."))
            #expect(message.contains("Provide at least one screenshot for the 6.7-inch display."))
            #expect(message.contains("A privacy policy URL is required."))
            #expect(message.contains("Set a privacy policy URL for this version."))
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }
    }

    @Test func notFoundIsReportedAsIsWithoutMetadataHint() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await mock.failNext(
            "POST", "reviewSubmissions",
            withErrorBody:
                "{\"errors\":[{\"status\":\"404\",\"code\":\"NOT_FOUND\",\"title\":\"The specified resource does not exist.\",\"detail\":\"There is no resource of type 'reviewSubmissions' with id 'x'.\"}]}"
        )

        do {
            _ = try await ReviewSubmissionService(client: mock)
                .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
            Issue.record("A 404 must throw so the command exits non-zero")
        } catch let error as AppctlError {
            let message = error.diagnosticMessage
            #expect(message.contains("HTTP 404"))
            #expect(message.contains("The specified resource does not exist."))
            #expect(message.contains("There is no resource of type 'reviewSubmissions' with id 'x'."))
            #expect(!message.contains("Fix:"), "an unrecognized code must be reported as-is, with no heuristic hint")
            #expect(!message.contains("metadata"), "a 404 must never be misdiagnosed as a metadata problem")
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }
    }

    @Test func entityErrorGetsMetadataFixHint() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await mock.queue(Self.createdSubmission)
        await mock.failNext(
            "POST", "reviewSubmissionItems",
            withErrorBody:
                "{\"errors\":[{\"status\":\"409\",\"code\":\"ENTITY_ERROR.ATTRIBUTE.REQUIRED\",\"title\":\"The provided entity is missing a required attribute.\",\"detail\":\"You must provide a value for the attribute 'description'.\"}]}"
        )

        do {
            _ = try await ReviewSubmissionService(client: mock)
                .submit(appId: "app-1", platform: "IOS", versionId: "ver-1")
            Issue.record("The failed submission must throw so the command exits non-zero")
        } catch let error as AppctlError {
            let message = error.diagnosticMessage
            #expect(message.contains("You must provide a value for the attribute 'description'."))
            #expect(message.contains("Fix:"))
            #expect(message.contains("metadata"), "ENTITY_ERROR codes must carry the complete-metadata hint")
        } catch {
            Issue.record("Expected AppctlError, got \(error)")
        }
    }

    @Test func cancelSearchesAllOpenStatesAndPatchesCanceled() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            "{\"data\":[{\"type\":\"reviewSubmissions\",\"id\":\"rs-5\",\"attributes\":{\"state\":\"WAITING_FOR_REVIEW\",\"platform\":\"IOS\"}}]}"
        )
        await mock.queue(
            "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-5\",\"attributes\":{\"state\":\"CANCELING\"}}}"
        )

        let canceled = try await ReviewSubmissionService(client: mock).cancel(appId: "app-1", platform: "IOS")
        #expect(canceled.id == "rs-5")

        let requests = await mock.requests
        let lookup = try #require(requests.first)
        #expect(
            lookup.queryItems?.contains(
                URLQueryItem(
                    name: "filter[state]",
                    value: "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES")) == true,
            "cancel must search every non-terminal state, not just READY_FOR_REVIEW")

        let patch = try #require(requests.last)
        #expect(patch.method == "PATCH")
        #expect(patch.path == "reviewSubmissions/rs-5")
        let body = try jsonObject(patch.body)
        let attributes = nested(body, "data", "attributes")
        #expect(attributes["canceled"] as? Bool == true)
        #expect(attributes["submitted"] == nil, "submitted must be omitted when canceling")
    }

    @Test func cancelWithNoOpenSubmissionThrowsNotFound() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.emptyList)
        await #expect(throws: AppctlError.self) {
            try await ReviewSubmissionService(client: mock).cancel(appId: "app-1", platform: "IOS")
        }
    }

    @Test func decodeReviewSubmission() throws {
        let j =
            "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"rs-1\",\"attributes\":{\"platform\":\"IOS\",\"state\":\"READY_FOR_REVIEW\",\"submittedDate\":null}}}"
            .data(using: .utf8)
        let r = try JSONDecoder().decode(APIResponse<ReviewSubmission>.self, from: try #require(j))
        #expect(r.data.id == "rs-1")
        #expect(r.data.attributes?.state == "READY_FOR_REVIEW")
        #expect(r.data.attributes?.platform == "IOS")
    }
}
