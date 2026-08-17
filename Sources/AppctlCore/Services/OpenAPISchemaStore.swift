import Foundation

/// The subset of Apple's App Store Connect OpenAPI document that `appctl api
/// --list` and `--schema` render. Everything else in the ~7 MB spec is ignored
/// at decode time.
public struct OpenAPISpec: Decodable, Sendable {
    public struct Info: Decodable, Sendable { public let version: String }
    public struct Components: Decodable, Sendable { public let schemas: [String: JSONValue]? }
    public let info: Info
    public let paths: [String: PathItem]
    public let components: Components?
}

public struct PathItem: Decodable, Sendable {
    public let get: APIOperation?
    public let post: APIOperation?
    public let patch: APIOperation?
    public let delete: APIOperation?

    /// Operations in conventional method order for stable rendering.
    public var operations: [(method: String, operation: APIOperation)] {
        [("GET", get), ("POST", post), ("PATCH", patch), ("DELETE", delete)]
            .compactMap { method, op in op.map { (method, $0) } }
    }
}

public struct APIOperation: Decodable, Sendable {
    public let operationId: String?
    public let deprecated: Bool?
    public let parameters: [APIParameter]?
    public let requestBody: APIRequestBody?
}

public struct APIParameter: Decodable, Sendable {
    public let name: String
    public let location: String?
    public let description: String?
    public let required: Bool?
    public let schema: JSONValue?
    enum CodingKeys: String, CodingKey {
        case name, description, required, schema
        case location = "in"
    }
}

public struct APIRequestBody: Decodable, Sendable {
    public let content: [String: APIMediaType]?
    public let required: Bool?
}

public struct APIMediaType: Decodable, Sendable { public let schema: JSONValue? }

/// Lazily downloads and caches Apple's OpenAPI specification under `~/.appctl`.
/// Purely advisory: `appctl api` never consults it to execute a request, so a
/// missing or stale cache only degrades `--list`/`--schema`.
public struct OpenAPISchemaStore: Sendable {
    public static let specURLString =
        "https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip"

    public let cacheURL: URL
    private let runner: any ProcessRunner

    public init(cacheDirectory: URL? = nil, runner: any ProcessRunner = SubprocessRunner()) {
        let directory =
            cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appctl")
        self.cacheURL = directory.appendingPathComponent("openapi.json")
        self.runner = runner
    }

    /// Returns the cached spec, downloading it on first use.
    public func loadSpec() async throws -> OpenAPISpec {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return try await refresh()
        }
        guard let data = FileManager.default.contents(atPath: cacheURL.path) else {
            throw AppctlError.schemaUnavailable(reason: "The cached spec at \(cacheURL.path) is unreadable.")
        }
        do {
            return try Self.parse(data)
        } catch {
            throw AppctlError.schemaUnavailable(
                reason: "The cached spec at \(cacheURL.path) is corrupt or has an unexpected format.")
        }
    }

    /// Downloads a fresh copy of the spec, replacing any cached one.
    public func refresh() async throws -> OpenAPISpec {
        var stderr = StandardError.shared
        print("Fetching the App Store Connect OpenAPI spec from Apple (one-time, ~7 MB unpacked)…", to: &stderr)
        guard let url = URL(string: Self.specURLString) else {
            throw AppctlError.schemaUnavailable(reason: "The spec download URL is malformed.")
        }
        let zipData: Data
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw AppctlError.schemaUnavailable(reason: "Apple returned HTTP \(status) for the spec download.")
            }
            zipData = data
        } catch let error as AppctlError {
            throw error
        } catch {
            throw AppctlError.schemaUnavailable(reason: "Download failed: \(error.localizedDescription)")
        }

        let json = try await unzippedSpec(zipData)
        let spec: OpenAPISpec
        do {
            spec = try Self.parse(json)
        } catch {
            throw AppctlError.schemaUnavailable(reason: "The downloaded spec did not parse as OpenAPI JSON.")
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: cacheURL, options: .atomic)
        } catch {
            throw AppctlError.fileWriteError(path: cacheURL.path, reason: error.localizedDescription)
        }
        return spec
    }

    public static func parse(_ data: Data) throws -> OpenAPISpec {
        try JSONDecoder().decode(OpenAPISpec.self, from: data)
    }

    /// Apple ships the spec as a zip with a single JSON entry (plus macOS metadata).
    private func unzippedSpec(_ zipData: Data) async throws -> Data {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-openapi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = workDir.appendingPathComponent("spec.zip")
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try zipData.write(to: zipURL)
        } catch {
            throw AppctlError.fileWriteError(path: zipURL.path, reason: error.localizedDescription)
        }
        let exitCode = try await runner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-o", "-q", zipURL.path, "-d", workDir.path],
            onOutputLine: { _ in })
        guard exitCode == 0 else {
            throw AppctlError.schemaUnavailable(
                reason: "Unpacking the downloaded spec failed (unzip exit \(exitCode)).")
        }
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let jsonURL = entries.first(where: { $0.pathExtension == "json" }),
            let json = FileManager.default.contents(atPath: jsonURL.path)
        else {
            throw AppctlError.schemaUnavailable(reason: "The downloaded archive contained no JSON spec.")
        }
        return json
    }

    // MARK: - Rendering

    public static func renderList(_ spec: OpenAPISpec, filter: String?) -> String {
        let needle = filter?.lowercased()
        var lines: [String] = []
        for path in spec.paths.keys.sorted() {
            guard let item = spec.paths[path] else { continue }
            for (method, operation) in item.operations {
                if let needle,
                    !path.lowercased().contains(needle),
                    !(operation.operationId?.lowercased().contains(needle) ?? false)
                {
                    continue
                }
                let deprecated = operation.deprecated == true ? "  (deprecated)" : ""
                lines.append("\(method.padding(toLength: 7, withPad: " ", startingAt: 0))\(path)\(deprecated)")
            }
        }
        guard !lines.isEmpty else {
            return "No endpoints match '\(filter ?? "")' (spec version \(spec.info.version))."
        }
        lines.append("")
        lines.append(
            "\(lines.count - 1) endpoints (spec version \(spec.info.version)). "
                + "Use `appctl api --schema <path>` for details.")
        return lines.joined(separator: "\n")
    }

    public static func renderSchema(_ spec: OpenAPISpec, path rawPath: String) -> String {
        let lookupPath = normalizedSchemaPath(rawPath)
        guard let (specPath, item) = match(spec, path: lookupPath) else {
            return "No schema entry for '\(lookupPath)' (spec version \(spec.info.version)).\n"
                + "The schema is advisory — unknown paths still execute. "
                + "Try `appctl api --list <term>` to search."
        }
        var sections: [String] = []
        for (method, operation) in item.operations {
            var lines: [String] = []
            let opId = operation.operationId.map { " — \($0)" } ?? ""
            let deprecated = operation.deprecated == true ? "  (deprecated)" : ""
            lines.append("\(method) \(specPath)\(opId)\(deprecated)")
            let queryParams = (operation.parameters ?? []).filter { $0.location == "query" }
            if !queryParams.isEmpty {
                lines.append("  Query parameters:")
                for param in queryParams {
                    let required = param.required == true ? ", required" : ""
                    let description = param.description.map { " — \($0)" } ?? ""
                    lines.append("    \(param.name) (\(typeName(param.schema))\(required))\(description)")
                }
            }
            if let bodyLines = requestBodyLines(operation: operation, spec: spec) {
                lines.append(contentsOf: bodyLines)
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Accepts `/v1/apps`, `v1/apps`, or bare `apps` (→ `/v1/apps`), matching how
    /// `appctl api` itself normalizes execution paths.
    static func normalizedSchemaPath(_ raw: String) -> String {
        var trimmed = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        if let query = trimmed.firstIndex(of: "?") { trimmed = String(trimmed[..<query]) }
        let first = trimmed.split(separator: "/").first.map(String.init) ?? ""
        let isVersioned = first.count >= 2 && first.hasPrefix("v") && first.dropFirst().allSatisfy(\.isNumber)
        return "/" + (isVersioned ? trimmed : "v1/" + trimmed)
    }

    /// Exact match first, then template matching so a concrete path like
    /// `/v1/apps/12345` finds `/v1/apps/{id}`.
    private static func match(_ spec: OpenAPISpec, path: String) -> (String, PathItem)? {
        if let item = spec.paths[path] { return (path, item) }
        let segments = path.split(separator: "/")
        for (candidate, item) in spec.paths {
            let candidateSegments = candidate.split(separator: "/")
            guard candidateSegments.count == segments.count else { continue }
            let matches = zip(candidateSegments, segments).allSatisfy { template, actual in
                template == actual || (template.hasPrefix("{") && template.hasSuffix("}"))
            }
            if matches { return (candidate, item) }
        }
        return nil
    }

    private static func requestBodyLines(operation: APIOperation, spec: OpenAPISpec) -> [String]? {
        guard let media = operation.requestBody?.content?["application/json"] else { return nil }
        guard let ref = media.schema?["$ref"]?.string, let resolved = resolveRef(ref, spec: spec) else {
            return ["  Request body: (inline schema — see the spec JSON)"]
        }
        let refName = ref.split(separator: "/").last.map(String.init) ?? ref
        var lines = ["  Request body (\(refName)):"]
        let dataProperties = resolved["properties"]?["data"]?["properties"]
        if let typeValue = dataProperties?["type"]?["enum"]?.array?.first?.string {
            lines.append("    data.type: \"\(typeValue)\"")
        }
        if let attributes = dataProperties?["attributes"] {
            let requiredNames = attributes["required"]?.array?.compactMap(\.string) ?? []
            if let properties = attributes["properties"]?.object, !properties.isEmpty {
                lines.append("    data.attributes:")
                for name in properties.keys.sorted() {
                    let required = requiredNames.contains(name) ? ", required" : ""
                    lines.append("      \(name) (\(typeName(properties[name]))\(required))")
                }
            }
        }
        if let relationships = dataProperties?["relationships"]?["properties"]?.object,
            !relationships.isEmpty
        {
            lines.append("    data.relationships: \(relationships.keys.sorted().joined(separator: ", "))")
        }
        return lines
    }

    private static func resolveRef(_ ref: String, spec: OpenAPISpec) -> JSONValue? {
        guard ref.hasPrefix("#/components/schemas/"), let name = ref.split(separator: "/").last else {
            return nil
        }
        return spec.components?.schemas?[String(name)]
    }

    private static func typeName(_ schema: JSONValue?) -> String {
        guard let schema else { return "unknown" }
        if let ref = schema["$ref"]?.string {
            return ref.split(separator: "/").last.map(String.init) ?? "object"
        }
        let type = schema["type"]?.string ?? "unknown"
        if type == "array" { return "[\(typeName(schema["items"]))]" }
        return type
    }
}
