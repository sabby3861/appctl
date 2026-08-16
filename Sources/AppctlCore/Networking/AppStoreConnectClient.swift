import Foundation

/// Hard ceiling on pages a single `getList` will follow (1000 × 200 = 200k items) so a
/// misbehaving server that keeps handing out `next` links cannot hold a CI job hostage.
private let paginationPageCap = 1000

/// Abstraction over the App Store Connect HTTP client so commands and services can be
/// exercised against a mock. The concrete `APIClient` is constructed only in
/// `GlobalOptions.apiClient()`.
public protocol AppStoreConnectClient: Sendable {
    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]?) async throws -> T
    func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T
    func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T
    func delete(_ path: String) async throws
    func postVoid(_ path: String, body: Encodable & Sendable) async throws
    func patchVoid(_ path: String, body: Encodable & Sendable) async throws
    /// Sends raw bytes to a pre-signed upload URL exactly as an upload operation
    /// instructs: the operation's method and headers verbatim, no JWT attached.
    /// Deliberately has no default implementation — every conformer must decide how
    /// bytes leave the process (real PUT, fixture no-op, or mock recording).
    func uploadBytes(_ body: Data, to url: String, method: String, headers: [String: String]) async throws
    /// Diagnostic detail (pagination progress); shown only in verbose mode.
    func logDebug(_ message: String) async
    /// Non-fatal anomalies (pagination safety stops); must stay visible without verbose.
    func logWarning(_ message: String) async
}

extension AppStoreConnectClient {
    public func logDebug(_ message: String) async {}

    public func logWarning(_ message: String) async {
        var stderr = StandardError.shared
        print("⚠ \(message)", to: &stderr)
    }

    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(path, queryItems: nil)
    }

    /// Fetches a JSON:API collection, following `links.next` until the requested
    /// number of items is accumulated or pages are exhausted.
    ///
    /// Lives here rather than on `APIClient` so every conformer — including the test
    /// mock and the offline fixture client — runs the same pagination logic.
    ///
    /// - Parameters:
    ///   - limit: Maximum total items to return; `nil` fetches every page.
    ///   - pageSize: Per-page `limit` query parameter, clamped to the ASC maximum of 200.
    public func getList<T: Decodable>(
        _ path: String, queryItems: [URLQueryItem]? = nil,
        limit: Int? = nil, pageSize: Int = 200
    ) async throws -> APIListResponse<T> {
        let perPage = max(1, min(pageSize, 200, limit ?? 200))
        var firstPageQuery = (queryItems ?? []).filter { $0.name != "limit" }
        firstPageQuery.append(URLQueryItem(name: "limit", value: String(perPage)))

        var page: APIListResponse<T> = try await get(path, queryItems: firstPageQuery)
        var data = page.data
        var included = page.included ?? []
        var meta = page.meta
        var pages = 1
        var lastFetchedURL: String?
        await logDebug(Self.pageSummary(path: path, page: 1, pageData: page, runningTotal: data.count))

        while let next = page.links?.next {
            if let limit, data.count >= limit { break }
            // Documented ASC bug: some endpoints return an empty page that still
            // carries a next link; following it would spin forever.
            if page.data.isEmpty {
                await logDebug("getList \(path): empty page with a next link (known ASC bug); stopping.")
                break
            }
            if next == lastFetchedURL {
                await logWarning(
                    "Pagination stopped: \(path) repeated its own next link (known ASC bug). "
                        + "Results may be incomplete (\(data.count) items).")
                break
            }
            if pages >= paginationPageCap {
                await logWarning(
                    "Pagination stopped at the \(paginationPageCap)-page safety cap for \(path) "
                        + "(\(data.count) items). Results may be incomplete; narrow the query with filters.")
                break
            }
            lastFetchedURL = next
            page = try await get(next)
            pages += 1
            data.append(contentsOf: page.data)
            if let pageIncluded = page.included { included.append(contentsOf: pageIncluded) }
            if let pageMeta = page.meta { meta = pageMeta }
            await logDebug(Self.pageSummary(path: path, page: pages, pageData: page, runningTotal: data.count))
        }

        if let limit, data.count > limit { data = Array(data.prefix(limit)) }
        if pages >= 3 {
            // Straight to stderr rather than through `OutputFormatter` (like the
            // legacy-submit deprecation warning) so it stays visible in `--format json`
            // mode without contaminating stdout.
            var stderr = StandardError.shared
            let hint = limit == nil ? "; use --limit to cap" : ""
            print("Fetched \(data.count) items across \(pages) pages\(hint).", to: &stderr)
        }
        return APIListResponse(
            data: data, included: included.isEmpty ? nil : included,
            links: nil, meta: meta, pagesFetched: pages)
    }

    private static func pageSummary<T>(
        path: String, page: Int, pageData: APIListResponse<T>, runningTotal: Int
    ) -> String {
        let total = pageData.meta?.paging?.total.map(String.init) ?? "unknown"
        return "getList \(path): page \(page) — \(pageData.data.count) item(s), "
            + "running total \(runningTotal), meta.paging.total: \(total)"
    }
}

extension APIClient: AppStoreConnectClient {}
