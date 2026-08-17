import Foundation

/// The versioned JSON output envelope — the v1 contract every JSON-mode command
/// emits (see docs/agent-guide.md). Changing a field's name or type is a breaking
/// change to that contract and needs an `apiVersion` bump.
public struct Envelope: Encodable, Sendable {
    public static let currentAPIVersion = "appctl/v1"

    public let apiVersion: String
    public let data: JSONValue
    public let warnings: [String]
    /// Present only on failure: { code, exitClass, message, docs }.
    public let error: JSONValue?
    /// Action name → a literal, ready-to-run appctl command (state-aware; built
    /// via `NextActions`). Always present, null when nothing sensible follows.
    public let next: [String: String]?

    public init(
        data: JSONValue, warnings: [String] = [], error: JSONValue? = nil,
        next: [String: String]? = nil
    ) {
        self.apiVersion = Self.currentAPIVersion
        self.data = data
        self.warnings = warnings
        self.error = error
        self.next = next
    }

    /// The envelope for a failed command: data is null, `error` carries the
    /// stable code and its exit class so agents can branch without parsing text.
    public static func failure(_ error: AppctlError) -> Envelope {
        let code = error.errorCode
        return Envelope(
            data: .null,
            error: .object([
                "code": .string(code.rawValue),
                "exitClass": .int(Int(code.exitClass)),
                "message": .string(error.diagnosticMessage),
                "docs": .string(code.docsURL),
            ]))
    }

    enum CodingKeys: String, CodingKey { case apiVersion, data, warnings, error, next }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiVersion, forKey: .apiVersion)
        try c.encode(data, forKey: .data)
        try c.encode(warnings, forKey: .warnings)
        try c.encodeIfPresent(error, forKey: .error)
        // Always present (null when there is no follow-up) so consumers can key off it.
        try c.encode(next, forKey: .next)
    }
}
