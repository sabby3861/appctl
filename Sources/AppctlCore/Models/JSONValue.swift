import Foundation

/// A lossless JSON document value. The `api` command uses it to pass arbitrary
/// request bodies and responses through the typed `AppStoreConnectClient` seam
/// without knowing the endpoint's schema.
///
/// Object key order is not preserved (dictionary-backed); callers that print
/// JSON should encode with `.sortedKeys` for deterministic output.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Value is not representable as JSON.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var int: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    /// Parses a standalone JSON fragment (`5`, `true`, `"x"`, `[1,2]`, `{"a":1}`).
    /// `JSONDecoder` rejects top-level scalars on older platforms, so the fragment
    /// is decoded wrapped in an array.
    public static func fragment(_ text: String) throws -> JSONValue {
        let wrapped = Data("[\(text)]".utf8)
        let decoded = try JSONDecoder().decode([JSONValue].self, from: wrapped)
        guard decoded.count == 1, let value = decoded.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [], debugDescription: "Expected a single JSON value."))
        }
        return value
    }
}
