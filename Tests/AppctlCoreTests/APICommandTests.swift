import Foundation
import Testing

@testable import AppctlCore

/// `appctl api` seam tests: request construction, JSON:API body shape, pagination
/// aggregation, DELETE confirmation, the audit hook, and schema rendering.

private let base = "https://api.appstoreconnect.apple.com"

@Suite("api command — GET") struct APICommandGetTests {
    @Test func normalizesBarePathsToV1AndMergesFields() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":[]}"#)

        _ = try await APICommand.execute(
            client: mock, method: "get", path: "apps?limit=5",
            fields: ["filter[bundleId]=com.example.app"], inputBody: nil,
            paginate: false, limit: nil, pageSize: 200, confirm: false, dryRun: false, audit: nil)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "\(base)/v1/apps", "bare paths default to /v1; query is split out")
        let items = try #require(requests[0].queryItems)
        #expect(items.contains(URLQueryItem(name: "limit", value: "5")))
        #expect(items.contains(URLQueryItem(name: "filter[bundleId]", value: "com.example.app")))
    }

    @Test func preservesExplicitVersionPrefix() throws {
        let (url, _) = try APICommand.normalize(path: "/v2/inAppPurchases")
        #expect(url == "\(base)/v2/inAppPurchases")
    }

    @Test func rejectsForeignHosts() async throws {
        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "GET", path: "https://evil.example.com/v1/apps",
                fields: [], inputBody: nil, paginate: false, limit: nil, pageSize: 200,
                confirm: false, dryRun: false, audit: nil)
        }
        #expect(await mock.requests.isEmpty, "the signed token must never leave the ASC host")
    }

    @Test func hoistsNextLinkIntoOutcome() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            #"{"data":[{"type":"apps","id":"a1"}],"links":{"next":"\#(base)/v1/apps?cursor=x"}}"#)

        let outcome = try await APICommand.execute(
            client: mock, method: "GET", path: "/v1/apps", fields: [], inputBody: nil,
            paginate: false, limit: nil, pageSize: 200, confirm: false, dryRun: false, audit: nil)

        #expect(outcome.next == "\(base)/v1/apps?cursor=x")
        #expect(outcome.executed)
    }
}

@Suite("api command — pagination") struct APICommandPaginateTests {
    @Test func aggregatesAllPagesFollowingNextLinks() async throws {
        let mock = MockAppStoreConnectClient()
        let next = "\(base)/v1/betaGroups?cursor=p2"
        await mock.queue(
            #"{"data":[{"type":"betaGroups","id":"g1"},{"type":"betaGroups","id":"g2"}],"links":{"next":"\#(next)"},"meta":{"paging":{"total":3}}}"#
        )
        await mock.queue(
            #"{"data":[{"type":"betaGroups","id":"g3"}],"meta":{"paging":{"total":3}}}"#)

        let outcome = try await APICommand.execute(
            client: mock, method: "GET", path: "/v1/betaGroups", fields: [], inputBody: nil,
            paginate: true, limit: nil, pageSize: 200, confirm: false, dryRun: false, audit: nil)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[1].path == next, "the second request follows links.next verbatim")
        let data = try #require(outcome.document["data"]?.array)
        #expect(data.count == 3, "pages are aggregated into one document")
        #expect(outcome.next == nil, "a fully paginated response has no next link")
        let total = outcome.document["meta"]?["paging"]?["total"]?.int
        #expect(total == 3, "meta from the last page is preserved")
    }

    @Test func trimsAggregateToLimit() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(
            #"{"data":[{"type":"apps","id":"a1"},{"type":"apps","id":"a2"}],"links":{"next":"\#(base)/v1/apps?cursor=p2"}}"#
        )
        await mock.queue(#"{"data":[{"type":"apps","id":"a3"},{"type":"apps","id":"a4"}]}"#)

        let outcome = try await APICommand.execute(
            client: mock, method: "GET", path: "/v1/apps", fields: [], inputBody: nil,
            paginate: true, limit: 3, pageSize: 2, confirm: false, dryRun: false, audit: nil)

        #expect(outcome.document["data"]?.array?.count == 3)
    }

    @Test func rejectsPaginateOnMutations() async throws {
        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "POST", path: "/v1/betaGroups", fields: ["name=X"],
                inputBody: nil, paginate: true, limit: nil, pageSize: 200,
                confirm: false, dryRun: false, audit: nil)
        }
        #expect(await mock.requests.isEmpty)
    }

    @Test func rejectsLimitWithoutPaginate() async throws {
        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "GET", path: "/v1/apps", fields: [], inputBody: nil,
                paginate: false, limit: 10, pageSize: 200, confirm: false, dryRun: false,
                audit: nil)
        }
        #expect(await mock.requests.isEmpty, "--limit is a pagination control, not a query param")
    }
}

@Suite("api command — mutations") struct APICommandMutationTests {
    private func tempAuditTrail() -> APIAuditTrail {
        APIAuditTrail(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("appctl-test-\(UUID().uuidString)/audit.log"))
    }

    @Test func postBuildsJSONAPIBodyFromFields() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"betaGroups","id":"bg-1"}}"#)

        _ = try await APICommand.execute(
            client: mock, method: "POST", path: "/v1/betaGroups",
            fields: ["name=External", "publicLinkEnabled:=true", "publicLinkLimit:=25"],
            inputBody: nil, paginate: false, limit: nil, pageSize: 200,
            confirm: false, dryRun: false, audit: tempAuditTrail())

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "POST")
        let body = try jsonObject(requests[0].body)
        let data = nested(body, "data")
        #expect(data["type"] as? String == "betaGroups", "type is derived from the last path segment")
        let attributes = nested(body, "data", "attributes")
        #expect(attributes["name"] as? String == "External", "k=v assigns a string")
        #expect(attributes["publicLinkEnabled"] as? Bool == true, "k:=json assigns typed values")
        #expect(attributes["publicLinkLimit"] as? Int == 25)
        #expect(data["id"] == nil, "POST bodies carry no id")
    }

    @Test func patchDerivesTypeAndIdFromPath() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"betaGroups","id":"bg-1"}}"#)

        _ = try await APICommand.execute(
            client: mock, method: "PATCH", path: "/v1/betaGroups/bg-1", fields: ["name=Renamed"],
            inputBody: nil, paginate: false, limit: nil, pageSize: 200,
            confirm: false, dryRun: false, audit: tempAuditTrail())

        let body = try jsonObject((await mock.requests)[0].body)
        let data = nested(body, "data")
        #expect(data["type"] as? String == "betaGroups")
        #expect(data["id"] as? String == "bg-1")
    }

    @Test func inputFileBodyIsSentVerbatim() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"betaGroups","id":"bg-1"}}"#)
        let input = Data(
            #"{"data":{"type":"betaGroups","relationships":{"app":{"data":{"type":"apps","id":"a1"}}}}}"#.utf8)

        _ = try await APICommand.execute(
            client: mock, method: "POST", path: "/v1/betaGroups", fields: [], inputBody: input,
            paginate: false, limit: nil, pageSize: 200, confirm: false, dryRun: false,
            audit: tempAuditTrail())

        let body = try jsonObject((await mock.requests)[0].body)
        let appRef = nested(body, "data", "relationships", "app", "data")
        #expect(appRef["id"] as? String == "a1")
    }

    @Test func rejectsFieldsCombinedWithInput() async throws {
        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "POST", path: "/v1/betaGroups", fields: ["name=X"],
                inputBody: Data("{}".utf8), paginate: false, limit: nil, pageSize: 200,
                confirm: false, dryRun: false, audit: nil)
        }
        #expect(await mock.requests.isEmpty)
    }

    @Test func deleteWithoutConfirmAbortsBeforeAnyRequest() async throws {
        let mock = MockAppStoreConnectClient()
        let audit = tempAuditTrail()

        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "DELETE", path: "/v1/betaGroups/bg-1", fields: [],
                inputBody: nil, paginate: false, limit: nil, pageSize: 200,
                confirm: false, dryRun: false, audit: audit)
        }
        #expect(await mock.requests.isEmpty, "refusal must happen before any request is issued")
        #expect(
            !FileManager.default.fileExists(atPath: audit.fileURL.path),
            "an aborted DELETE is not a mutation and must not be audited")
    }

    @Test func executedMutationWritesOneAuditLine() async throws {
        let mock = MockAppStoreConnectClient()
        let audit = tempAuditTrail()

        let outcome = try await APICommand.execute(
            client: mock, method: "DELETE", path: "/v1/betaGroups/bg-1", fields: [],
            inputBody: nil, paginate: false, limit: nil, pageSize: 200,
            confirm: true, dryRun: false, audit: audit)

        #expect(outcome.document == .null, "a 204 DELETE has no document")
        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "DELETE")

        let contents = try #require(FileManager.default.contents(atPath: audit.fileURL.path))
        let lines = String(decoding: contents, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        try #require(lines.count == 1)
        let entry = try jsonObject(Data(lines[0].utf8))
        #expect(entry["command"] as? String == "api")
        #expect(entry["method"] as? String == "DELETE")
        #expect(entry["url"] as? String == "\(base)/v1/betaGroups/bg-1")
        #expect(entry["timestamp"] is String)
    }

    @Test func dryRunPreviewsWithoutExecutingOrAuditing() async throws {
        let mock = MockAppStoreConnectClient()
        let audit = tempAuditTrail()

        let outcome = try await APICommand.execute(
            client: mock, method: "POST", path: "/v1/betaGroups", fields: ["name=X"],
            inputBody: nil, paginate: false, limit: nil, pageSize: 200,
            confirm: false, dryRun: true, audit: audit)

        #expect(await mock.requests.isEmpty)
        #expect(!outcome.executed)
        #expect(outcome.document["dryRun"] == .bool(true))
        #expect(outcome.document["method"]?.string == "POST")
        #expect(outcome.document["body"]?["data"]?["attributes"]?["name"] == .string("X"))
        #expect(!FileManager.default.fileExists(atPath: audit.fileURL.path))
    }
}

@Suite("api command — field parsing") struct APICommandFieldTests {
    @Test func stringAndJSONAssignments() throws {
        guard case .string(let key, let value) = try APICommand.parseField("name=a=b") else {
            Issue.record("expected a string assignment")
            return
        }
        #expect(key == "name")
        #expect(value == "a=b", "everything after the first = is the value")

        guard case .json(let jsonKey, let jsonValue) = try APICommand.parseField("count:=5") else {
            Issue.record("expected a JSON assignment")
            return
        }
        #expect(jsonKey == "count")
        #expect(jsonValue == .int(5))
    }

    @Test func rejectsMalformedAssignments() {
        #expect(throws: AppctlError.self) { _ = try APICommand.parseField("novalue") }
        #expect(throws: AppctlError.self) { _ = try APICommand.parseField("=x") }
        #expect(throws: AppctlError.self) { _ = try APICommand.parseField("count:=not-json") }
    }

    @Test func rejectsTypedFieldsOnGet() async throws {
        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await APICommand.execute(
                client: mock, method: "GET", path: "/v1/apps", fields: ["limit:=5"],
                inputBody: nil, paginate: false, limit: nil, pageSize: 200,
                confirm: false, dryRun: false, audit: nil)
        }
    }
}

@Suite("api command — envelope") struct EnvelopeTests {
    @Test func envelopeShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Envelope(data: .object(["data": .array([])]), next: nil))
        let object = try jsonObject(data)
        #expect(object["apiVersion"] as? String == "appctl/v1")
        #expect(object["warnings"] as? [String] == [])
        #expect(object["next"] is NSNull, "next is always present, null when exhausted")
        #expect(object["error"] == nil, "error is omitted until V5's taxonomy lands")
        #expect(object["data"] != nil)
    }
}

@Suite("api command — schema rendering") struct SchemaRenderingTests {
    private static let fixtureSpec = """
        {
          "openapi": "3.0.1",
          "info": {"title": "App Store Connect API", "version": "4.4.1"},
          "paths": {
            "/v1/betaGroups": {
              "get": {
                "operationId": "betaGroups_getCollection",
                "parameters": [
                  {"name": "filter[name]", "in": "query", "description": "filter by name",
                   "schema": {"type": "array", "items": {"type": "string"}}}
                ]
              },
              "post": {
                "operationId": "betaGroups_createInstance",
                "requestBody": {
                  "content": {"application/json": {"schema": {"$ref": "#/components/schemas/BetaGroupCreateRequest"}}},
                  "required": true
                }
              }
            },
            "/v1/betaGroups/{id}": {
              "delete": {"operationId": "betaGroups_deleteInstance"}
            }
          },
          "components": {
            "schemas": {
              "BetaGroupCreateRequest": {
                "type": "object",
                "properties": {
                  "data": {
                    "type": "object",
                    "properties": {
                      "type": {"type": "string", "enum": ["betaGroups"]},
                      "attributes": {
                        "type": "object",
                        "properties": {
                          "name": {"type": "string"},
                          "publicLinkEnabled": {"type": "boolean"}
                        },
                        "required": ["name"]
                      },
                      "relationships": {
                        "type": "object",
                        "properties": {"app": {"type": "object"}}
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

    private func spec() throws -> OpenAPISpec {
        try OpenAPISchemaStore.parse(Data(Self.fixtureSpec.utf8))
    }

    @Test func rendersKnownEndpoint() throws {
        let rendered = OpenAPISchemaStore.renderSchema(try spec(), path: "/v1/betaGroups")
        #expect(rendered.contains("GET /v1/betaGroups — betaGroups_getCollection"))
        #expect(rendered.contains("filter[name] ([string]) — filter by name"))
        #expect(rendered.contains("POST /v1/betaGroups — betaGroups_createInstance"))
        #expect(rendered.contains("Request body (BetaGroupCreateRequest):"))
        #expect(rendered.contains("data.type: \"betaGroups\""))
        #expect(rendered.contains("name (string, required)"))
        #expect(rendered.contains("publicLinkEnabled (boolean)"))
        #expect(rendered.contains("data.relationships: app"))
    }

    @Test func matchesConcreteIdsAgainstTemplates() throws {
        let rendered = OpenAPISchemaStore.renderSchema(try spec(), path: "betaGroups/bg-123")
        #expect(rendered.contains("DELETE /v1/betaGroups/{id} — betaGroups_deleteInstance"))
    }

    @Test func unknownPathDegradesGracefully() throws {
        let rendered = OpenAPISchemaStore.renderSchema(try spec(), path: "/v1/nonexistent")
        #expect(rendered.contains("No schema entry for '/v1/nonexistent'"))
        #expect(rendered.contains("unknown paths still execute"))
    }

    @Test func listFiltersAcrossPathAndOperationId() throws {
        let all = OpenAPISchemaStore.renderList(try spec(), filter: nil)
        #expect(all.contains("GET    /v1/betaGroups"))
        #expect(all.contains("DELETE /v1/betaGroups/{id}"))

        let filtered = OpenAPISchemaStore.renderList(try spec(), filter: "deleteInstance")
        #expect(filtered.contains("DELETE /v1/betaGroups/{id}"))
        #expect(!filtered.contains("POST   /v1/betaGroups"))

        let none = OpenAPISchemaStore.renderList(try spec(), filter: "zzz")
        #expect(none.contains("No endpoints match"))
    }
}
