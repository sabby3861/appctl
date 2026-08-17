import Foundation

// `@unchecked Sendable`: every stored property is a `let`, but `URLSession` and
// `JSONDecoder` are not formally `Sendable`. Both are documented as safe to share
// across threads when used read-only as we do here (decoder is configured once at init,
// session is thread-safe per Apple's URL Loading System docs).
public final class APIClient: @unchecked Sendable {
    public static let baseURL = "https://api.appstoreconnect.apple.com/v1"
    private let jwtGenerator: JWTGenerator
    private let session: URLSession
    /// Separate session for raw byte uploads: a multi-hundred-MB part on a slow uplink
    /// would trip the API session's `timeoutIntervalForResource` (3× the request
    /// timeout, 90s by default), so uploads get their own generous resource window.
    private let uploadSession: URLSession
    private let transport: any HTTPTransport
    private let verbose: Bool
    private let decoder: JSONDecoder
    private let retryBaseDelay: TimeInterval

    /// `transport` defaults to the real URLSession; tests inject a scripted one
    /// (and a near-zero `retryBaseDelay`) to exercise the retry policy without
    /// a network or real sleeps.
    public init(
        jwtGenerator: JWTGenerator, verbose: Bool = false, timeout: TimeInterval = 30,
        transport: (any HTTPTransport)? = nil, retryBaseDelay: TimeInterval = 1.0
    ) {
        self.jwtGenerator = jwtGenerator
        self.verbose = verbose
        self.retryBaseDelay = retryBaseDelay
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpAdditionalHeaders = ["User-Agent": "appctl/\(AppctlVersion.current) (Swift; macOS)"]
        self.session = URLSession(configuration: config)
        self.transport = transport ?? URLSessionTransport(session: session)
        let uploadConfig = URLSessionConfiguration.default
        uploadConfig.timeoutIntervalForRequest = 300
        uploadConfig.timeoutIntervalForResource = 3600
        uploadConfig.httpAdditionalHeaders = config.httpAdditionalHeaders
        self.uploadSession = URLSession(configuration: uploadConfig)
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

    /// Single-attempt by design: the build-upload service owns per-part retry policy,
    /// so retrying here as well would multiply attempts.
    public func uploadBytes(_ body: Data, to url: String, method: String, headers: [String: String]) async throws {
        guard let requestURL = URL(string: url) else {
            throw AppctlError.invalidInput(field: "url", value: url, expected: "A valid upload operation URL")
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        if verbose {
            var s = StandardError.shared
            print("  → \(method) \(url) (\(body.count) bytes)", to: &s)
        }
        let (data, response) = try await uploadSession.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw AppctlError.invalidResponse(url: url, reason: "Not an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppctlError.requestFailed(
                url: url, statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
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

    /// Failure budgets are tracked per `RetryStrategy` category: a request that
    /// waits out a 429 still has its full 5xx and transport budgets. `backoff`
    /// consumes one unit and reports whether another attempt is allowed.
    private func executeWithRetry<T: Decodable>(_ request: URLRequest) async throws -> T {
        var failures: [RetryStrategy: Int] = [:]

        func backoff(_ strategy: RetryStrategy, retryAfter: TimeInterval? = nil) async throws -> Bool {
            let count = failures[strategy, default: 0] + 1
            failures[strategy] = count
            guard count < strategy.maxAttempts else { return false }
            try await Task.sleep(
                for: RetryStrategy.delay(
                    for: strategy, attempt: count - 1, retryAfter: retryAfter, base: retryBaseDelay))
            return true
        }

        while true {
            do {
                if verbose {
                    var s = StandardError.shared
                    let attempt = failures.values.reduce(0, +)
                    print(
                        "  → \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")\(attempt > 0 ? " (retry \(attempt))" : "")",
                        to: &s)
                }
                let (data, http) = try await transport.data(for: request)
                if verbose {
                    var s = StandardError.shared
                    print(
                        "  ← \(http.statusCode) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))",
                        to: &s)
                }

                if (200...299).contains(http.statusCode) {
                    if data.isEmpty || http.statusCode == 204 {
                        if let empty = EmptyResponse() as? T { return empty }
                        // Schemaless callers (the `api` command) decode into JSONValue,
                        // where a successful 204 is simply "no document".
                        if let null = JSONValue.null as? T { return null }
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
                    let retryAfter =
                        http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0) } ?? 5.0
                    if try await backoff(.rateLimited, retryAfter: retryAfter) { continue }
                    throw AppctlError.rateLimited(
                        retryAfter: min(retryAfter, RetryStrategy.delayCap))
                }
                if http.statusCode >= 500 {
                    if try await backoff(.serverError) { continue }
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
                switch e.code {
                case .timedOut:
                    throw AppctlError.timeout(url: request.url?.absoluteString ?? "", duration: request.timeoutInterval)
                case .notConnectedToInternet, .networkConnectionLost:
                    throw AppctlError.connectionFailed(host: request.url?.host ?? "", reason: "No internet connection.")
                default:
                    if try await backoff(.transport) { continue }
                    throw AppctlError.connectionFailed(host: request.url?.host ?? "", reason: e.localizedDescription)
                }
            } catch {
                if try await backoff(.transport) { continue }
                throw AppctlError.connectionFailed(
                    host: request.url?.host ?? "api.appstoreconnect.apple.com",
                    reason: error.localizedDescription)
            }
        }
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
