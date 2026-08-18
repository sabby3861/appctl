import Crypto
import Foundation

/// One audited mutation: a single NDJSON line in `~/.appctl/audit/<year-month>.ndjson`.
/// The schema is a stable contract (task V9) — `appctl history` and future tooling
/// parse these lines back, so fields are only ever added, never renamed.
struct AuditEntry: Codable, Sendable {
    /// ISO 8601 with fractional seconds; also selects the monthly log file.
    let ts: String
    /// The invoking command line, credential-redacted via `redactedCommand`.
    let command: String
    /// Canonical request path with query, e.g. `/v1/appStoreVersions/123`.
    let endpoint: String
    let method: String
    /// First path segment after the API version — the JSON:API collection.
    let resourceType: String
    /// Second path segment when present; absent for creations (POST to a collection).
    let resourceId: String?
    /// SHA-256 hex of the request body encoded with sorted keys (the canonical
    /// form, not necessarily the wire bytes); bodiless requests digest empty data.
    let requestDigest: String
    /// GET-before-write snapshot, captured only for snapshot-eligible types.
    let priorState: JSONValue?

    static func requestDigest(of body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// Flags whose values are credentials and must never reach the log.
    private static let credentialFlags: Set<String> = [
        "--key-id", "--issuer-id", "--private-key-path",
    ]

    /// Rebuilds the invoking command line with credential material removed:
    /// values of credential flags (both `--flag VALUE` and `--flag=VALUE` forms),
    /// any token containing inline PEM material, and the directory portion of any
    /// `.p8` path wherever it appears (the filename alone is not a secret and
    /// keeps the entry attributable to a key).
    static func redactedCommand(arguments: [String]) -> String {
        var tokens: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext {
                tokens.append("<redacted>")
                redactNext = false
                continue
            }
            if credentialFlags.contains(argument) {
                tokens.append(argument)
                redactNext = true
                continue
            }
            if let eq = argument.firstIndex(of: "="),
                credentialFlags.contains(String(argument[..<eq]))
            {
                tokens.append("\(argument[..<eq])=<redacted>")
                continue
            }
            tokens.append(redactingKeyMaterial(argument))
        }
        return tokens.joined(separator: " ")
    }

    private static func redactingKeyMaterial(_ token: String) -> String {
        if token.contains("BEGIN PRIVATE KEY") { return "<redacted>" }
        if token.hasSuffix(".p8") {
            let name = URL(fileURLWithPath: token).lastPathComponent
            return token == name ? name : "<redacted>/\(name)"
        }
        return token
    }
}
