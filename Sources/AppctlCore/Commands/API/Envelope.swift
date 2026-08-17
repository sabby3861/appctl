import Foundation

/// The versioned JSON output envelope. Currently emitted only by `appctl api`;
/// rolling it out across all commands is task V5 (together with the stable
/// error-code taxonomy), so nothing else should adopt it piecemeal.
public struct Envelope: Encodable, Sendable {
    public static let currentAPIVersion = "appctl/v1"

    public let apiVersion: String
    public let data: JSONValue
    public let warnings: [String]
    /// Reserved for V5's error taxonomy: today failures throw through the
    /// What/Why/Fix formatter instead of being embedded here.
    public let error: JSONValue?
    public let next: String?

    public init(data: JSONValue, warnings: [String] = [], error: JSONValue? = nil, next: String? = nil) {
        self.apiVersion = Self.currentAPIVersion
        self.data = data
        self.warnings = warnings
        self.error = error
        self.next = next
    }

    enum CodingKeys: String, CodingKey { case apiVersion, data, warnings, error, next }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiVersion, forKey: .apiVersion)
        try c.encode(data, forKey: .data)
        try c.encode(warnings, forKey: .warnings)
        try c.encodeIfPresent(error, forKey: .error)
        // Always present (null when exhausted) so consumers can key off it.
        try c.encode(next, forKey: .next)
    }
}
