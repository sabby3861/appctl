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

/// Minimal view of one page of a paginated JSON:API response, so the shared
/// pagination engine (`getPages`) can drive both typed lists (`APIListResponse`)
/// and the `api` command's schemaless raw documents through the same loop guards.
public protocol PaginatedDocument: Decodable {
    var pageItemCount: Int { get }
    var nextLink: String? { get }
    var pagingTotal: Int? { get }
}

extension APIListResponse: PaginatedDocument {
    public var pageItemCount: Int { data.count }
    public var nextLink: String? { links?.next }
    public var pagingTotal: Int? { meta?.paging?.total }
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

    /// The pagination engine: fetches a JSON:API collection page by page, following
    /// `links.next` until the requested number of items is accumulated or pages are
    /// exhausted, and returns every page for the caller to merge.
    ///
    /// Lives here rather than on `APIClient` so every conformer — including the test
    /// mock and the offline fixture client — runs the same pagination logic.
    ///
    /// - Parameters:
    ///   - limit: Maximum total items to accumulate; `nil` fetches every page.
    ///   - pageSize: Per-page `limit` query parameter, clamped to the ASC maximum of 200.
    public func getPages<P: PaginatedDocument>(
        _ path: String, queryItems: [URLQueryItem]? = nil,
        limit: Int? = nil, pageSize: Int = 200
    ) async throws -> [P] {
        let perPage = max(1, min(pageSize, 200, limit ?? 200))
        var firstPageQuery = (queryItems ?? []).filter { $0.name != "limit" }
        firstPageQuery.append(URLQueryItem(name: "limit", value: String(perPage)))

        var page: P = try await get(path, queryItems: firstPageQuery)
        var pages = [page]
        var itemCount = page.pageItemCount
        var lastFetchedURL: String?
        await logDebug(Self.pageSummary(path: path, page: 1, pageDoc: page, runningTotal: itemCount))

        while let next = page.nextLink {
            if let limit, itemCount >= limit { break }
            // Documented ASC bug: some endpoints return an empty page that still
            // carries a next link; following it would spin forever.
            if page.pageItemCount == 0 {
                await logDebug("getList \(path): empty page with a next link (known ASC bug); stopping.")
                break
            }
            if next == lastFetchedURL {
                await logWarning(
                    "Pagination stopped: \(path) repeated its own next link (known ASC bug). "
                        + "Results may be incomplete (\(itemCount) items).")
                break
            }
            if pages.count >= paginationPageCap {
                await logWarning(
                    "Pagination stopped at the \(paginationPageCap)-page safety cap for \(path) "
                        + "(\(itemCount) items). Results may be incomplete; narrow the query with filters.")
                break
            }
            lastFetchedURL = next
            page = try await get(next)
            pages.append(page)
            itemCount += page.pageItemCount
            await logDebug(
                Self.pageSummary(path: path, page: pages.count, pageDoc: page, runningTotal: itemCount))
        }

        if pages.count >= 3 {
            // Straight to stderr rather than through `OutputFormatter` (like the
            // legacy-submit deprecation warning) so it stays visible in `--format json`
            // mode without contaminating stdout.
            var stderr = StandardError.shared
            let shown = limit.map { min($0, itemCount) } ?? itemCount
            let hint = limit == nil ? "; use --limit to cap" : ""
            print("Fetched \(shown) items across \(pages.count) pages\(hint).", to: &stderr)
        }
        return pages
    }

    /// Fetches a JSON:API collection via `getPages` and merges the pages into a
    /// single aggregated response.
    public func getList<T: Decodable>(
        _ path: String, queryItems: [URLQueryItem]? = nil,
        limit: Int? = nil, pageSize: Int = 200
    ) async throws -> APIListResponse<T> {
        let pages: [APIListResponse<T>] = try await getPages(
            path, queryItems: queryItems, limit: limit, pageSize: pageSize)
        var data = pages.flatMap(\.data)
        if let limit, data.count > limit { data = Array(data.prefix(limit)) }
        let included = pages.compactMap(\.included).flatMap { $0 }
        return APIListResponse(
            data: data, included: included.isEmpty ? nil : included,
            links: nil, meta: pages.reversed().compactMap(\.meta).first,
            pagesFetched: pages.count)
    }

    private static func pageSummary<P: PaginatedDocument>(
        path: String, page: Int, pageDoc: P, runningTotal: Int
    ) -> String {
        let total = pageDoc.pagingTotal.map(String.init) ?? "unknown"
        return "getList \(path): page \(page) — \(pageDoc.pageItemCount) item(s), "
            + "running total \(runningTotal), meta.paging.total: \(total)"
    }
}

extension APIClient: AppStoreConnectClient {}
