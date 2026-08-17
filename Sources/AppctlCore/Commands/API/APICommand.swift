import ArgumentParser
import Foundation

/// `appctl api` — a signed escape hatch onto the App Store Connect API for
/// endpoints appctl has no dedicated command for.
public struct APICommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Make a signed request to any App Store Connect API endpoint.",
        discussion: """
            Examples:
              appctl api GET /v1/apps --field 'filter[bundleId]=com.example.app'
              appctl api GET /v1/betaGroups --paginate
              appctl api POST /v1/betaGroups --field name=External --field 'publicLinkEnabled:=true'
              appctl api PATCH /v1/betaGroups/GROUP_ID --field name=Renamed
              appctl api DELETE /v1/betaGroups/GROUP_ID --confirm
              appctl api --list betaGroups
              appctl api --schema /v1/betaGroups

            Field rules:
              On GET, --field k=v adds a query parameter.
              On POST/PATCH, --field builds a JSON:API body { "data": { "type", "id",
              "attributes" } }: k=v sets data.attributes.k to the string "v", and
              k:=JSON sets it to raw JSON (numbers, booleans, arrays, objects —
              e.g. 'publicLinkLimit:=25'). The reserved keys type= and id= set
              data.type / data.id. When omitted, data.type defaults to the last path
              segment on POST; on a PATCH path ending in an ID, data.type defaults to
              the second-to-last segment and data.id to the last. Bodies needing
              relationships use --input with a full JSON document instead.

            Paths may be given as /v1/…, /v2/…, or bare (apps → /v1/apps). The OpenAPI
            schema behind --list/--schema is advisory: unknown paths still execute.
            """)
    public init() {}

    @Argument(help: "HTTP method: GET, POST, PATCH, or DELETE. With --list, an optional filter term.")
    var method: String?
    @Argument(help: "API path, e.g. /v1/apps.") var path: String?
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Request field as k=v, or k:=JSON for typed body values. Repeatable.",
            valueName: "k=v"))
    var field: [String] = []
    @Option(name: .long, help: "Read the full JSON request body from a file (POST/PATCH).")
    var input: String?
    @Flag(name: .long, help: "Follow links.next and aggregate every page (GET only).")
    var paginate = false
    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Print the server response without the appctl envelope.",
            discussion: "The response is re-serialized with sorted keys — not byte-identical to the wire response."))
    var raw = false
    @Flag(name: .long, help: "Required to execute DELETE requests.") var confirm = false
    @Flag(name: .long, help: "Print the request that would be sent without executing it.")
    var dryRun = false
    @Flag(name: .customLong("list"), help: "List known endpoints from the OpenAPI schema.")
    var listEndpoints = false
    @Option(
        name: .customLong("schema"),
        help: ArgumentHelp("Show the OpenAPI schema for an API path.", valueName: "path"))
    var schemaFor: String?
    @Flag(name: .customLong("update-schema"), help: "Refresh the cached OpenAPI schema from Apple.")
    var updateSchema = false
    @OptionGroup var pagination: PaginationOptions
    @OptionGroup var globals: GlobalOptions

    public func run() async throws {
        if updateSchema || listEndpoints || schemaFor != nil {
            try await runSchemaModes()
            return
        }
        guard let method, let path else {
            throw AppctlError.invalidInput(
                field: "arguments", value: [method, path].compactMap { $0 }.joined(separator: " "),
                expected: "METHOD PATH (e.g. `appctl api GET /v1/apps`), or --list / --schema / --update-schema"
            )
        }
        let (limit, pageSize) = try pagination.validated()
        let inputBody = try input.map { try Self.readInputFile($0) }
        let (client, _) = try globals.apiClient()
        let outcome = try await Self.execute(
            client: client, method: method, path: path, fields: field, inputBody: inputBody,
            paginate: paginate, limit: limit, pageSize: pageSize,
            confirm: confirm, dryRun: dryRun,
            // Mock mode is a rehearsal: nothing real changed, so nothing is audited.
            audit: globals.mock ? nil : APIAuditTrail())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload =
            raw
            ? try encoder.encode(outcome.document)
            : try encoder.encode(Envelope(data: outcome.document, next: outcome.next))
        print(String(decoding: payload, as: UTF8.self))
    }

    private func runSchemaModes() async throws {
        let store = OpenAPISchemaStore()
        var spec: OpenAPISpec?
        if updateSchema {
            let refreshed = try await store.refresh()
            spec = refreshed
            print(
                "✓ Schema cache updated → \(store.cacheURL.path) "
                    + "(spec version \(refreshed.info.version), \(refreshed.paths.count) paths)")
        }
        if listEndpoints || schemaFor != nil {
            let loaded: OpenAPISpec
            if let spec {
                loaded = spec
            } else {
                loaded = try await store.loadSpec()
            }
            if listEndpoints {
                // With --list the first positional doubles as the filter term.
                print(OpenAPISchemaStore.renderList(loaded, filter: method))
            }
            if let schemaPath = schemaFor {
                print(OpenAPISchemaStore.renderSchema(loaded, path: schemaPath))
            }
        }
    }

    // MARK: - Execution seam

    enum Method: String, CaseIterable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
        var isMutation: Bool { self != .get }
    }

    struct Outcome: Sendable {
        let document: JSONValue
        /// Hoisted `links.next`; nil when absent or after full pagination.
        let next: String?
        /// False for dry runs, which never issue a request.
        let executed: Bool
    }

    static func execute(
        client: any AppStoreConnectClient, method methodString: String, path: String,
        fields: [String], inputBody: Data?, paginate: Bool, limit: Int?, pageSize: Int,
        confirm: Bool, dryRun: Bool, audit: APIAuditTrail?
    ) async throws -> Outcome {
        guard let method = Method(rawValue: methodString.uppercased()) else {
            throw AppctlError.invalidInput(
                field: "METHOD", value: methodString,
                expected: Method.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if paginate, method != .get {
            throw AppctlError.invalidInput(
                field: "--paginate", value: method.rawValue,
                expected: "GET (pagination applies to collection reads)")
        }
        if !paginate, limit != nil || pageSize != 200 {
            throw AppctlError.invalidInput(
                field: "--limit/--page-size", value: "without --paginate",
                expected: "Combine with --paginate; a single request takes --field limit=N instead")
        }
        let (baseURL, pathQuery) = try normalize(path: path)
        let assignments = try fields.map(parseField)
        let body = try requestBody(
            for: method, baseURL: baseURL, assignments: assignments, inputBody: inputBody)

        var queryItems = pathQuery
        if method == .get {
            for case .string(let key, let value) in assignments {
                queryItems.append(URLQueryItem(name: key, value: value))
            }
        }
        let fullURL = try embeddingQuery(queryItems, into: baseURL)

        if dryRun {
            var request: [String: JSONValue] = [
                "dryRun": .bool(true), "method": .string(method.rawValue), "url": .string(fullURL),
            ]
            if let body { request["body"] = body }
            return Outcome(document: .object(request), next: nil, executed: false)
        }
        if method == .delete, !confirm {
            throw AppctlError.confirmationRequired(operation: "DELETE \(fullURL)")
        }

        let document: JSONValue
        var next: String?
        switch method {
        case .get where paginate:
            let pages: [RawPage] = try await client.getPages(
                baseURL, queryItems: queryItems, limit: limit, pageSize: pageSize)
            document = mergePages(pages, limit: limit)
        case .get:
            document = try await client.get(baseURL, queryItems: queryItems.isEmpty ? nil : queryItems)
            next = document["links"]?["next"]?.string
        case .post:
            guard let body else { throw missingBody(for: method) }
            document = try await client.post(fullURL, body: body)
        case .patch:
            guard let body else { throw missingBody(for: method) }
            document = try await client.patch(fullURL, body: body)
        case .delete:
            try await client.delete(fullURL)
            document = .null
        }

        if method.isMutation, let audit {
            do {
                try audit.record(method: method.rawValue, url: fullURL)
            } catch {
                // The mutation already succeeded; failing the command now would
                // mislead. Surface the audit problem without masking the result.
                var stderr = StandardError.shared
                print("⚠ Audit log write failed: \(error.localizedDescription)", to: &stderr)
            }
        }
        return Outcome(document: document, next: next, executed: true)
    }

    // MARK: - Path handling

    static let apiHost = "api.appstoreconnect.apple.com"

    /// Normalizes user input to an absolute URL with its query string split out.
    /// Bare paths default to /v1; versioned paths (/v2/…) pass through, which the
    /// client's own base URL (ending in /v1) could not express. Absolute URLs are
    /// pinned to the ASC host so the signed JWT can never be sent elsewhere.
    static func normalize(path: String) throws -> (baseURL: String, query: [URLQueryItem]) {
        var absolute = path
        if !path.hasPrefix("https://") {
            if path.contains("://") {
                throw AppctlError.invalidInput(
                    field: "path", value: path, expected: "An https:// URL or an API path like /v1/apps")
            }
            var trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let firstSegment = trimmed.split(separator: "/").first.flatMap { $0.split(separator: "?").first }
            let isVersioned =
                firstSegment.map { $0.count >= 2 && $0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber) }
                ?? false
            if !isVersioned { trimmed = "v1/" + trimmed }
            absolute = "https://\(apiHost)/\(trimmed)"
        }
        guard var components = URLComponents(string: absolute), components.host == apiHost,
            !components.path.isEmpty
        else {
            throw AppctlError.invalidInput(
                field: "path", value: path,
                expected: "A path on https://\(apiHost) (the signed token is never sent to other hosts)")
        }
        let query = components.queryItems ?? []
        components.queryItems = nil
        components.fragment = nil
        guard let url = components.url else {
            throw AppctlError.invalidInput(field: "path", value: path, expected: "A constructable URL")
        }
        return (url.absoluteString, query)
    }

    private static func embeddingQuery(_ items: [URLQueryItem], into baseURL: String) throws -> String {
        guard !items.isEmpty else { return baseURL }
        guard var components = URLComponents(string: baseURL) else {
            throw AppctlError.invalidInput(field: "path", value: baseURL, expected: "A constructable URL")
        }
        components.queryItems = items
        guard let url = components.url else {
            throw AppctlError.invalidInput(field: "path", value: baseURL, expected: "A constructable URL")
        }
        return url.absoluteString
    }

    // MARK: - Field parsing and body construction

    enum FieldAssignment {
        case string(key: String, value: String)
        case json(key: String, value: JSONValue)
    }

    /// `k=v` assigns a string; `k:=JSON` assigns a raw JSON fragment. The first `=`
    /// decides, so values may themselves contain `=` or `:=`.
    static func parseField(_ raw: String) throws -> FieldAssignment {
        guard let eq = raw.firstIndex(of: "="), eq != raw.startIndex else {
            throw AppctlError.invalidInput(
                field: "--field", value: raw, expected: "k=v, or k:=JSON for typed values")
        }
        let beforeEq = raw.index(before: eq)
        if raw[beforeEq] == ":" {
            let key = String(raw[..<beforeEq])
            let fragment = String(raw[raw.index(after: eq)...])
            guard !key.isEmpty, let value = try? JSONValue.fragment(fragment) else {
                throw AppctlError.invalidInput(
                    field: "--field", value: raw,
                    expected: "k:=JSON with a valid JSON fragment (e.g. count:=5, enabled:=true)")
            }
            return .json(key: key, value: value)
        }
        return .string(key: String(raw[..<eq]), value: String(raw[raw.index(after: eq)...]))
    }

    private static func requestBody(
        for method: Method, baseURL: String, assignments: [FieldAssignment], inputBody: Data?
    ) throws -> JSONValue? {
        switch method {
        case .get, .delete:
            if inputBody != nil {
                throw AppctlError.invalidInput(
                    field: "--input", value: method.rawValue, expected: "POST or PATCH (these methods send a body)")
            }
            if method == .delete, !assignments.isEmpty {
                throw AppctlError.invalidInput(
                    field: "--field", value: method.rawValue,
                    expected: "GET (query params) or POST/PATCH (body attributes)")
            }
            for case .json(let key, _) in assignments {
                throw AppctlError.invalidInput(
                    field: "--field", value: "\(key):=…", expected: "k=v on GET; k:=JSON applies to POST/PATCH bodies")
            }
            return nil
        case .post, .patch:
            if let inputBody {
                guard assignments.isEmpty else {
                    throw AppctlError.invalidInput(
                        field: "--field", value: "combined with --input",
                        expected: "Either --field assignments or a full --input document, not both")
                }
                do {
                    return try JSONDecoder().decode(JSONValue.self, from: inputBody)
                } catch {
                    throw AppctlError.invalidInput(
                        field: "--input", value: "(file contents)", expected: "A valid JSON document")
                }
            }
            guard !assignments.isEmpty else {
                throw AppctlError.invalidInput(
                    field: method.rawValue, value: "no body",
                    expected: "--field assignments or --input with a JSON document")
            }
            return try jsonAPIBody(for: method, baseURL: baseURL, assignments: assignments)
        }
    }

    private static func jsonAPIBody(
        for method: Method, baseURL: String, assignments: [FieldAssignment]
    ) throws -> JSONValue {
        var type: String?
        var id: String?
        var attributes: [String: JSONValue] = [:]
        for assignment in assignments {
            switch assignment {
            case .string(let key, let value):
                switch key {
                case "type": type = value
                case "id": id = value
                default: attributes[key] = .string(value)
                }
            case .json(let key, let value):
                guard key != "type", key != "id" else {
                    throw AppctlError.invalidInput(
                        field: "--field", value: "\(key):=…", expected: "type and id are plain strings (type=v, id=v)")
                }
                attributes[key] = value
            }
        }

        // Default type/id from the path per the documented rule: POST → last
        // segment; PATCH …/{type}/{id} → second-to-last segment plus trailing ID.
        let segments = (URLComponents(string: baseURL)?.path ?? "")
            .split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let resourceSegments = Array(segments.dropFirst())
        if method == .patch, resourceSegments.count >= 2 {
            if type == nil { type = resourceSegments[resourceSegments.count - 2] }
            if id == nil { id = resourceSegments[resourceSegments.count - 1] }
        } else if type == nil {
            type = resourceSegments.last
        }
        guard let type else {
            throw AppctlError.invalidInput(
                field: "--field type", value: "(missing)",
                expected: "A JSON:API resource type; it could not be derived from the path")
        }

        var data: [String: JSONValue] = ["type": .string(type)]
        if let id { data["id"] = .string(id) }
        if !attributes.isEmpty { data["attributes"] = .object(attributes) }
        return .object(["data": .object(data)])
    }

    private static func missingBody(for method: Method) -> AppctlError {
        .invalidInput(
            field: method.rawValue, value: "no body",
            expected: "--field assignments or --input with a JSON document")
    }

    // MARK: - Raw pagination

    /// A page of an unknown collection endpoint, kept as a whole document so nothing
    /// (`included`, endpoint-specific `meta`) is dropped when pages are merged.
    struct RawPage: PaginatedDocument {
        let document: JSONValue
        init(from decoder: Decoder) throws { document = try JSONValue(from: decoder) }
        var pageItemCount: Int { document["data"]?.array?.count ?? 0 }
        var nextLink: String? { document["links"]?["next"]?.string }
        var pagingTotal: Int? { document["meta"]?["paging"]?["total"]?.int }
    }

    static func mergePages(_ pages: [RawPage], limit: Int?) -> JSONValue {
        var data: [JSONValue] = []
        var included: [JSONValue] = []
        var meta: JSONValue?
        for page in pages {
            data.append(contentsOf: page.document["data"]?.array ?? [])
            included.append(contentsOf: page.document["included"]?.array ?? [])
            if let pageMeta = page.document["meta"] { meta = pageMeta }
        }
        if let limit, data.count > limit { data = Array(data.prefix(limit)) }
        var merged: [String: JSONValue] = ["data": .array(data)]
        if !included.isEmpty { merged["included"] = .array(included) }
        if let meta { merged["meta"] = meta }
        return .object(merged)
    }

    // MARK: - Input file

    private static func readInputFile(_ path: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppctlError.fileNotFound(path: path)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AppctlError.fileNotReadable(path: path)
        }
        return data
    }
}
