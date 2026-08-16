import Foundation
import Testing

@testable import AppctlCore

/// Exercises the shared `getList` pagination loop in the `AppStoreConnectClient`
/// extension — the same code path every conformer (including `APIClient`) runs.
@Suite("getList pagination") struct PaginationTests {
    private struct Item: Decodable { let id: String }

    private static let nextURL = "https://api.appstoreconnect.apple.com/v1/things?cursor="

    private static func page(
        count: Int, startingAt offset: Int = 0, next: String? = nil, total: Int? = nil,
        includedIDs: [String] = []
    ) -> String {
        let data = (0..<count).map { "{\"type\":\"things\",\"id\":\"item-\(offset + $0)\"}" }
            .joined(separator: ",")
        var json = "{\"data\":[\(data)]"
        if !includedIDs.isEmpty {
            let included = includedIDs.map { "{\"type\":\"extras\",\"id\":\"\($0)\"}" }
                .joined(separator: ",")
            json += ",\"included\":[\(included)]"
        }
        if let next { json += ",\"links\":{\"next\":\"\(next)\"}" }
        if let total { json += ",\"meta\":{\"paging\":{\"total\":\(total),\"limit\":200}}" }
        return json + "}"
    }

    @Test func followsNextUntilAbsentAndAggregatesAllPages() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 200, next: Self.nextURL + "2", total: 437))
        await mock.queue(Self.page(count: 200, startingAt: 200, next: Self.nextURL + "3", total: 437))
        await mock.queue(Self.page(count: 37, startingAt: 400, total: 437))

        let r: APIListResponse<Item> = try await mock.getList("things")

        #expect(r.data.count == 437)
        #expect(r.data.first?.id == "item-0")
        #expect(r.data.last?.id == "item-436")
        #expect(r.pagesFetched == 3)
        #expect(r.meta?.paging?.total == 437, "meta must survive aggregation so paging.total is reported")
        #expect(r.links?.next == nil, "an aggregated response must not advertise further pages")

        let requests = await mock.requests
        try #require(requests.count == 3)
        #expect(requests[0].path == "things")
        #expect(requests[0].queryItems?.contains(URLQueryItem(name: "limit", value: "200")) == true)
        #expect(requests[1].path == Self.nextURL + "2")
        #expect(requests[2].path == Self.nextURL + "3")
    }

    @Test func emptyPageWithNextLinkTerminates() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 5, next: Self.nextURL + "2"))
        await mock.queue(Self.page(count: 0, startingAt: 5, next: Self.nextURL + "3"))

        let r: APIListResponse<Item> = try await mock.getList("things")

        #expect(r.data.count == 5)
        #expect(r.pagesFetched == 2)
        #expect(await mock.requests.count == 2, "the empty page's next link must not be followed")
    }

    @Test func limitReturnsExactlyThatManyItems() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 200, next: Self.nextURL + "2"))

        let r: APIListResponse<Item> = try await mock.getList("things", limit: 50)

        #expect(r.data.count == 50)
        #expect(r.data.last?.id == "item-49")

        let requests = await mock.requests
        try #require(requests.count == 1, "the limit was satisfied by one page; next must not be followed")
        #expect(
            requests[0].queryItems?.contains(URLQueryItem(name: "limit", value: "50")) == true,
            "per-page limit shrinks to the total limit when smaller than the page size")
    }

    @Test func limitSpanningMultiplePagesTruncatesExactly() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 200, next: Self.nextURL + "2"))
        await mock.queue(Self.page(count: 200, startingAt: 200, next: Self.nextURL + "3"))

        let r: APIListResponse<Item> = try await mock.getList("things", limit: 250)

        #expect(r.data.count == 250)
        #expect(r.data.last?.id == "item-249")
        #expect(await mock.requests.count == 2)
    }

    @Test func pageSizeIsClampedToASCMaximum() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 1))

        let _: APIListResponse<Item> = try await mock.getList("things", pageSize: 999)

        let items = try #require(await mock.requests.first?.queryItems)
        #expect(items.contains(URLQueryItem(name: "limit", value: "200")), "ASC caps per-page limit at 200")
    }

    @Test func includedResourcesAggregateAcrossPages() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 2, next: Self.nextURL + "2", includedIDs: ["extra-1"]))
        await mock.queue(Self.page(count: 1, startingAt: 2, includedIDs: ["extra-2"]))

        let r: APIListResponse<Item> = try await mock.getList("things")

        let included = try #require(r.included)
        #expect(included.map(\.id) == ["extra-1", "extra-2"], "included from later pages must survive")
    }

    @Test func repeatedNextLinkBreaksWithWarning() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 3, next: Self.nextURL + "2"))
        await mock.queue(Self.page(count: 3, startingAt: 3, next: Self.nextURL + "2"))

        let r: APIListResponse<Item> = try await mock.getList("things")

        #expect(r.data.count == 6)
        #expect(await mock.requests.count == 2, "a next link equal to the page just fetched must not loop")
        let warnings = await mock.warnings
        try #require(warnings.count == 1)
        #expect(warnings[0].contains("repeated its own next link"))
    }

    @Test func pageCapBreaksWithWarning() async throws {
        let mock = MockAppStoreConnectClient()
        for n in 0..<1_005 {
            await mock.queue(Self.page(count: 1, startingAt: n, next: Self.nextURL + String(n + 1)))
        }

        let r: APIListResponse<Item> = try await mock.getList("things")

        #expect(r.data.count == 1_000)
        #expect(await mock.requests.count == 1_000)
        let warnings = await mock.warnings
        try #require(warnings.count == 1)
        #expect(warnings[0].contains("1000-page safety cap"))
    }

    @Test func callerSuppliedLimitQueryItemIsReplaced() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.page(count: 1))

        let _: APIListResponse<Item> = try await mock.getList(
            "things", queryItems: [URLQueryItem(name: "limit", value: "7")], pageSize: 30)

        let items = try #require(await mock.requests.first?.queryItems)
        #expect(items.filter { $0.name == "limit" } == [URLQueryItem(name: "limit", value: "30")])
    }
}
