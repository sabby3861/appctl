import Foundation

/// Decorates the concrete client with the audit log: every mutating request that
/// succeeds appends one `AuditEntry`, with a GET-before-write snapshot for
/// snapshot-eligible types. Installed only in `GlobalOptions.apiClient()`, so all
/// mutation paths — typed commands, `api`, and future surfaces — are audited
/// through this single seam without per-command wiring. Reads pass through
/// untouched, which also guarantees the snapshot GET itself is never audited.
struct AuditingClient: AppStoreConnectClient {
    /// Types whose current state is small and losable enough to warrant a
    /// GET-before-write snapshot for undo. Growing this set is an audit-schema
    /// decision, not a convenience: every addition costs one extra GET per write.
    static let snapshotEligibleTypes: Set<String> = [
        "appStoreVersionLocalizations", "appInfoLocalizations",
        "appAvailabilities", "territoryAvailabilities",
    ]

    private let base: any AppStoreConnectClient
    private let log: AuditLog
    private let command: String

    init(
        wrapping base: any AppStoreConnectClient, log: AuditLog = AuditLog(),
        command: String = AuditEntry.redactedCommand(
            arguments: Array(CommandLine.arguments.dropFirst()))
    ) {
        self.base = base
        self.log = log
        self.command = command
    }

    // MARK: - Reads pass through

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]?) async throws -> T {
        try await base.get(path, queryItems: queryItems)
    }

    /// Pre-signed uploads carry raw asset bytes to a non-ASC host; the JSON:API
    /// reservation and commit calls around them are what the log records.
    func uploadBytes(
        _ body: Data, to url: String, method: String, headers: [String: String]
    ) async throws {
        try await base.uploadBytes(body, to: url, method: method, headers: headers)
    }

    func logDebug(_ message: String) async { await base.logDebug(message) }
    func logWarning(_ message: String) async { await base.logWarning(message) }

    // MARK: - Mutations are audited

    func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        let entry = try await prepareEntry(method: "POST", path: path, body: body)
        let result: T = try await base.post(path, body: body)
        await append(entry)
        return result
    }

    func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        let entry = try await prepareEntry(method: "PATCH", path: path, body: body)
        let result: T = try await base.patch(path, body: body)
        await append(entry)
        return result
    }

    func delete(_ path: String) async throws {
        let entry = try await prepareEntry(method: "DELETE", path: path, body: nil)
        try await base.delete(path)
        await append(entry)
    }

    func postVoid(_ path: String, body: Encodable & Sendable) async throws {
        let entry = try await prepareEntry(method: "POST", path: path, body: body)
        try await base.postVoid(path, body: body)
        await append(entry)
    }

    func patchVoid(_ path: String, body: Encodable & Sendable) async throws {
        let entry = try await prepareEntry(method: "PATCH", path: path, body: body)
        try await base.patchVoid(path, body: body)
        await append(entry)
    }

    // MARK: - Entry construction

    /// Built before the mutation executes (the snapshot must precede the write),
    /// but appended only after it succeeds — a failed call changed nothing.
    private func prepareEntry(
        method: String, path: String, body: (Encodable & Sendable)?
    ) async throws -> AuditEntry {
        let parsed = Self.parse(path: path)
        let bodyData: Data
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodyData = try encoder.encode(EncodableBox(body))
        } else {
            bodyData = Data()
        }
        var priorState: JSONValue?
        if method != "POST", let snapshotPath = parsed.snapshotPath {
            priorState = await snapshot(of: snapshotPath, endpoint: parsed.endpoint)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return AuditEntry(
            ts: formatter.string(from: Date()), command: command, endpoint: parsed.endpoint,
            method: method, resourceType: parsed.resourceType, resourceId: parsed.resourceId,
            requestDigest: AuditEntry.requestDigest(of: bodyData), priorState: priorState)
    }

    /// A single plain GET of the resource — never paginated, never `include`d, and
    /// through `base` so it is not itself audited. Snapshot failure must not block
    /// the mutation: warn and record the entry without priorState.
    private func snapshot(of path: String, endpoint: String) async -> JSONValue? {
        do {
            return try await base.get(path, queryItems: nil)
        } catch {
            var stderr = StandardError.shared
            print(
                "⚠ Audit snapshot of \(endpoint) failed: \(error.localizedDescription)",
                to: &stderr)
            return nil
        }
    }

    private func append(_ entry: AuditEntry) async {
        do {
            try await log.append(entry)
        } catch {
            // The mutation already succeeded; failing the command now would
            // mislead. Surface the audit problem without masking the result.
            var stderr = StandardError.shared
            print("⚠ Audit log write failed: \(error.localizedDescription)", to: &stderr)
        }
    }

    // MARK: - Path analysis

    struct ParsedPath {
        let endpoint: String
        let resourceType: String
        let resourceId: String?
        /// Set only for `{type}/{id}` paths on snapshot-eligible types, in the same
        /// absolute/relative form as the mutation path so the client resolves both
        /// against the same base URL.
        let snapshotPath: String?
    }

    /// Mutation paths arrive in two shapes: relative (`appStoreVersions/123`, typed
    /// commands, resolved against the client's /v1 base) and absolute
    /// (`https://…/v2/appAvailabilities/123?q=…`, the `api` command). Both normalize
    /// to a canonical `/vN/…` endpoint; the resource is the first segment after the
    /// version, its ID the second — so relationship paths
    /// (`appStoreVersions/{id}/relationships/build`) attribute to the parent.
    static func parse(path: String) -> ParsedPath {
        let withoutQuery: String
        let query: String?
        if let q = path.firstIndex(of: "?") {
            withoutQuery = String(path[..<q])
            query = String(path[path.index(after: q)...])
        } else {
            withoutQuery = path
            query = nil
        }

        var canonicalPath: String
        if withoutQuery.hasPrefix("https://") {
            canonicalPath = URLComponents(string: withoutQuery)?.path ?? withoutQuery
        } else {
            canonicalPath = withoutQuery.hasPrefix("/") ? withoutQuery : "/\(withoutQuery)"
        }
        var segments = canonicalPath.split(separator: "/").map(String.init)
        let isVersioned =
            segments.first.map {
                $0.count >= 2 && $0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber)
            } ?? false
        if !isVersioned {
            // Relative paths resolve against the client's base URL, which ends in /v1.
            segments.insert("v1", at: 0)
        }
        let endpoint = "/" + segments.joined(separator: "/") + (query.map { "?\($0)" } ?? "")

        let resourceSegments = Array(segments.dropFirst())
        let resourceType = resourceSegments.first ?? "unknown"
        let resourceId = resourceSegments.count >= 2 ? resourceSegments[1] : nil
        let snapshotPath =
            resourceSegments.count == 2 && snapshotEligibleTypes.contains(resourceType)
            ? withoutQuery : nil
        return ParsedPath(
            endpoint: endpoint, resourceType: resourceType, resourceId: resourceId,
            snapshotPath: snapshotPath)
    }
}

/// Type-erases the protocol's `Encodable & Sendable` bodies so the digest can be
/// computed without knowing the concrete request type.
private struct EncodableBox: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}
