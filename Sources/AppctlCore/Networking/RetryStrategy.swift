import Foundation

/// The transport seam under `APIClient`: swaps the real `URLSession` for a
/// scripted one in tests so retry behavior (429→200, 5xx storms) is verifiable
/// without a network.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppctlError.invalidResponse(
                url: request.url?.absoluteString ?? "", reason: "Not an HTTP response.")
        }
        return (data, http)
    }
}

/// Retry policy per failure category. Attempt budgets are independent — a request
/// that survives a 429 does not spend its 5xx budget.
public enum RetryStrategy: Sendable, Hashable {
    /// HTTP 429. The server is explicit about load, so we are patient: up to 5
    /// attempts, honoring `Retry-After` (clamped) or exponential backoff with jitter.
    case rateLimited
    /// HTTP 5xx: up to 3 attempts.
    case serverError
    /// URLError-level failures that are not clearly fatal: up to 3 attempts.
    case transport

    public var maxAttempts: Int {
        switch self {
        case .rateLimited: return 5
        case .serverError, .transport: return 3
        }
    }

    /// No computed delay ever exceeds this, protecting against both a hostile
    /// `Retry-After` header and exponential overflow.
    public static let delayCap: TimeInterval = 60

    /// The wait before the next attempt. Pure — jitter comes in through `random`
    /// so tests can pin it — and total: any inputs produce a delay in [0, cap].
    ///
    /// - Parameters:
    ///   - attempt: 0-based count of failures already seen in this category.
    ///   - retryAfter: The server's `Retry-After` seconds, if present. Honored
    ///     verbatim (clamped, no jitter): the server named its price.
    ///   - random: Source for equal jitter — the delay is `exp/2 + random(0...exp/2)`,
    ///     spreading concurrent clients while keeping at least half the backoff.
    public static func delay(
        for strategy: RetryStrategy, attempt: Int, retryAfter: TimeInterval? = nil,
        base: TimeInterval = 1.0,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> Duration {
        if let retryAfter {
            return .seconds(min(max(0, retryAfter), delayCap))
        }
        let exponential = min(delayCap, base * pow(2.0, Double(max(0, attempt))))
        let jittered = exponential / 2 + random(0...exponential / 2)
        return .seconds(min(delayCap, jittered))
    }
}
