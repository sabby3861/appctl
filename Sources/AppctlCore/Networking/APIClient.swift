import Foundation

// `@unchecked Sendable`: every stored property is a `let`, but `URLSession` and
// `JSONDecoder` are not formally `Sendable`. Both are documented as safe to share
// across threads when used read-only as we do here (decoder is configured once at init,
// session is thread-safe per Apple's URL Loading System docs).
public final class APIClient: @unchecked Sendable {
    public static let baseURL = "https://api.appstoreconnect.apple.com/v1"
    private let jwtGenerator: JWTGenerator
    private let session: URLSession
    private let verbose: Bool
    private let decoder: JSONDecoder
    private let maxRetries = 3
    private let baseRetryDelay: TimeInterval = 1.0
    /// Upper bound on how long we'll honor a `Retry-After` header — protects
    /// against a misconfigured or hostile server pinning us asleep for hours.
    private let maxRetryAfter: TimeInterval = 60

    public init(jwtGenerator: JWTGenerator, verbose: Bool = false, timeout: TimeInterval = 30) {
        self.jwtGenerator = jwtGenerator
        self.verbose = verbose
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpAdditionalHeaders = ["User-Agent": "appctl/\(AppctlVersion.current) (Swift; macOS)"]
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        try await executeWithRetry(try await buildRequest(method: "GET", path: path, queryItems: queryItems))
    }

    public func logDebug(_ message: String) {
        guard verbose else { return }
        var stderr = StandardError.shared
        print("  \(message)", to: &stderr)
    }

    public func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        var req = try await buildRequest(method: "POST", path: path)
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await executeWithRetry(req)
    }

    public func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        var req = try await buildRequest(method: "PATCH", path: path)
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await executeWithRetry(req)
    }

    public func delete(_ path: String) async throws {
        let _: EmptyResponse = try await executeWithRetry(try await buildRequest(method: "DELETE", path: path))
    }

    public func postVoid(_ path: String, body: Encodable & Sendable) async throws {
        var req = try await buildRequest(method: "POST", path: path)
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let _: EmptyResponse = try await executeWithRetry(req)
    }

    /// PATCH that expects a 204 No Content response, used for relationship endpoints
    /// (e.g. `/appStoreVersions/{id}/relationships/build`).
    public func patchVoid(_ path: String, body: Encodable & Sendable) async throws {
        var req = try await buildRequest(method: "PATCH", path: path)
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let _: EmptyResponse = try await executeWithRetry(req)
    }

    private func buildRequest(
        method: String, path: String, queryItems: [URLQueryItem]? = nil
    ) async throws -> URLRequest {
        let urlString =
            path.hasPrefix("https://")
            ? path : "\(Self.baseURL)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)"
        guard var components = URLComponents(string: urlString) else {
            throw AppctlError.invalidInput(field: "path", value: path, expected: "A valid API path")
        }
        if let items = queryItems, !items.isEmpty { components.queryItems = items }
        guard let url = components.url else {
            throw AppctlError.invalidInput(field: "url", value: urlString, expected: "A constructable URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await jwtGenerator.token())", forHTTPHeaderField: "Authorization")
        return req
    }

    private func executeWithRetry<T: Decodable>(_ request: URLRequest) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                if verbose {
                    var s = StandardError.shared
                    print(
                        "  → \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")\(attempt > 0 ? " (retry \(attempt))" : "")",
                        to: &s)
                }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AppctlError.invalidResponse(
                        url: request.url?.absoluteString ?? "", reason: "Not an HTTP response.")
                }
                if verbose {
                    var s = StandardError.shared
                    print(
                        "  ← \(http.statusCode) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))",
                        to: &s)
                }

                if (200...299).contains(http.statusCode) {
                    if data.isEmpty || http.statusCode == 204 {
                        if let empty = EmptyResponse() as? T { return empty }
                        throw AppctlError.invalidResponse(
                            url: request.url?.absoluteString ?? "",
                            reason: "Expected response body but received empty \(http.statusCode).")
                    }
                    do { return try decoder.decode(T.self, from: data) } catch {
                        throw AppctlError.invalidResponse(
                            url: request.url?.absoluteString ?? "",
                            reason: "Failed to decode: \(error.localizedDescription)")
                    }
                }
                if http.statusCode == 429 {
                    let raw = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 5.0
                    let wait = Self.clampedRetryAfter(raw, maximum: maxRetryAfter)
                    if attempt < maxRetries - 1 {
                        try await Task.sleep(for: .seconds(wait))
                        continue
                    }
                    throw AppctlError.rateLimited(retryAfter: wait)
                }
                if http.statusCode >= 500 && attempt < maxRetries - 1 {
                    try await Task.sleep(for: Self.backoffDelay(attempt: attempt, base: baseRetryDelay))
                    continue
                }
                if let errResp = try? decoder.decode(APIErrorResponse.self, from: data),
                    !errResp.errors.isEmpty
                {
                    throw AppctlError.apiError(
                        operation: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "?")",
                        statusCode: http.statusCode,
                        errors: errResp.errors)
                }
                throw AppctlError.requestFailed(
                    url: request.url?.absoluteString ?? "", statusCode: http.statusCode,
                    body: String(data: data, encoding: .utf8))
            } catch let e as AppctlError { throw e } catch is CancellationError {
                throw AppctlError.operationCancelled
            } catch let e as URLError {
                lastError = e
                switch e.code {
                case .timedOut:
                    throw AppctlError.timeout(url: request.url?.absoluteString ?? "", duration: request.timeoutInterval)
                case .notConnectedToInternet, .networkConnectionLost:
                    throw AppctlError.connectionFailed(host: request.url?.host ?? "", reason: "No internet connection.")
                default:
                    if attempt < maxRetries - 1 {
                        try await Task.sleep(for: Self.backoffDelay(attempt: attempt, base: baseRetryDelay))
                        continue
                    }
                    throw AppctlError.connectionFailed(host: request.url?.host ?? "", reason: e.localizedDescription)
                }
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    try await Task.sleep(for: Self.backoffDelay(attempt: attempt, base: baseRetryDelay))
                    continue
                }
            }
        }
        throw lastError
            ?? AppctlError.connectionFailed(
                host: "api.appstoreconnect.apple.com", reason: "Failed after \(maxRetries) attempts.")
    }

    /// Exponential backoff: `base × 2^attempt` seconds. Pure so it can be unit-tested
    /// without sleeping.
    static func backoffDelay(attempt: Int, base: TimeInterval) -> Duration {
        let seconds = base * pow(2.0, Double(attempt))
        return .seconds(seconds)
    }

    /// Cap a `Retry-After` header value to a sane maximum so a misconfigured or
    /// hostile server can't pin us asleep for hours.
    static func clampedRetryAfter(_ raw: TimeInterval, maximum: TimeInterval) -> TimeInterval {
        max(0, min(raw, maximum))
    }
}

public struct EmptyResponse: Decodable { public init() {} }
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}
public struct StandardError: TextOutputStream, Sendable {
    public static let shared = StandardError()
    public mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
