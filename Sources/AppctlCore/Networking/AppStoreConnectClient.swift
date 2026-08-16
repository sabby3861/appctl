import Foundation

/// Abstraction over the App Store Connect HTTP client so commands and services can be
/// exercised against a mock. The concrete `APIClient` is constructed only in
/// `GlobalOptions.apiClient()`.
public protocol AppStoreConnectClient: Sendable {
    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]?) async throws -> T
    func getList<T: Decodable>(
        _ path: String, queryItems: [URLQueryItem]?, limit: Int
    ) async throws
        -> APIListResponse<T>
    func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T
    func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T
    func delete(_ path: String) async throws
    func postVoid(_ path: String, body: Encodable & Sendable) async throws
    func patchVoid(_ path: String, body: Encodable & Sendable) async throws
}

// Protocols cannot carry default arguments, so the call-site conveniences the concrete
// client offered (`get(path)`, `getList(path)`) live here.
extension AppStoreConnectClient {
    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(path, queryItems: nil)
    }

    public func getList<T: Decodable>(
        _ path: String, queryItems: [URLQueryItem]? = nil
    ) async throws -> APIListResponse<T> {
        try await getList(path, queryItems: queryItems, limit: 200)
    }
}

extension APIClient: AppStoreConnectClient {}
