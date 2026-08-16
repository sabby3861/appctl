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
        private(set) var warnings: [String] = []
        private var responses: [Data] = []
        private var errorBodies: [String: [Data]] = [:]

        func queue(_ json: String) { responses.append(Data(json.utf8)) }

        func recordWarning(_ message: String) { warnings.append(message) }

        func failNext(_ method: String, _ path: String, withErrorBody json: String, times: Int = 1) {
            errorBodies["\(method) \(path)", default: []]
                .append(contentsOf: Array(repeating: Data(json.utf8), count: times))
        }

        func record(_ method: String, _ path: String, queryItems: [URLQueryItem]?, body: Data?) throws {
            requests.append(RecordedRequest(method: method, path: path, queryItems: queryItems, body: body))
            let key = "\(method) \(path)"
            if var queued = errorBodies[key], !queued.isEmpty {
                let errData = queued.removeFirst()
                errorBodies[key] = queued.isEmpty ? nil : queued
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

    /// Warnings the shared pagination layer emitted (safety-cap or repeated-link stops).
    var warnings: [String] {
        get async { await storage.warnings }
    }

    func logWarning(_ message: String) async { await storage.recordWarning(message) }

    func queue(_ json: String) async { await storage.queue(json) }

    func failNext(_ method: String, _ path: String, withErrorBody json: String, times: Int = 1) async {
        await storage.failNext(method, path, withErrorBody: json, times: times)
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

    /// Recorded with the upload URL as the path and the raw bytes as the body, in the
    /// same FIFO log as API requests — so create→file→PUT→confirm ordering is one
    /// assertion over `requests`. Headers are folded into query items for inspection.
    func uploadBytes(_ body: Data, to url: String, method: String, headers: [String: String]) async throws {
        let headerItems = headers.map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        try await storage.record(method, url, queryItems: headerItems, body: body)
    }
}

private struct EncodableBox: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    let d = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
}

func nested(_ dict: [String: Any], _ keys: String...) -> [String: Any] {
    var current = dict
    for key in keys {
        guard let next = current[key] as? [String: Any] else { return [:] }
        current = next
    }
    return current
}
