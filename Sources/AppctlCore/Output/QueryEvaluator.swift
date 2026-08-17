import Foundation

/// A small JMESPath-subset evaluator for `--query`, kept in-repo to avoid a
/// dependency. Supported: dot paths (`data.name`), indexes (`data[0]`, negative
/// from the end), wildcard projections (`data[*].id`), and equality filters
/// (`data[?state=='READY'].id`, `!=` also accepted; literals are 'strings',
/// numbers, true, false, null).
///
/// JMESPath semantics: expressions never fail at evaluation time — a path that
/// does not match yields null, and projections drop null results. Syntax errors
/// are caught once, at parse time.
public struct QueryEvaluator: Sendable {
    private enum Step: Sendable {
        case field(String)
        case index(Int)
        case wildcard
        case filter(path: [String], negated: Bool, literal: JSONValue)
    }

    private let steps: [Step]

    public init(parsing expression: String) throws {
        var parser = Parser(expression)
        self.steps = try parser.parseSteps()
    }

    public func evaluate(_ value: JSONValue) -> JSONValue {
        var current = value
        var projected = false
        for step in steps {
            if projected {
                guard let elements = current.array else { return .null }
                let mapped = elements.map { Self.apply(step, to: $0) }
                // A wildcard inside a projection flattens ([*][*] semantics).
                current = .array(
                    mapped.flatMap { v -> [JSONValue] in
                        if case .filter = step { return v.array ?? [] }
                        if case .wildcard = step { return v.array ?? [] }
                        if case .null = v { return [] }
                        return [v]
                    })
            } else {
                current = Self.apply(step, to: current)
                switch step {
                case .wildcard, .filter: projected = true
                case .field, .index: break
                }
            }
        }
        return current
    }

    private static func apply(_ step: Step, to value: JSONValue) -> JSONValue {
        switch step {
        case .field(let name):
            return value.object?[name] ?? .null
        case .index(let i):
            guard let arr = value.array else { return .null }
            let idx = i < 0 ? arr.count + i : i
            guard arr.indices.contains(idx) else { return .null }
            return arr[idx]
        case .wildcard:
            guard let arr = value.array else { return .null }
            return .array(arr.filter { $0 != .null })
        case .filter(let path, let negated, let literal):
            guard let arr = value.array else { return .null }
            return .array(
                arr.filter { element in
                    var resolved = element
                    for key in path { resolved = resolved.object?[key] ?? .null }
                    let matches = jsonEquals(resolved, literal)
                    return negated ? !matches : matches
                })
        }
    }

    /// Equality with numeric coercion so `[?count==5]` matches a JSON `5.0`.
    private static func jsonEquals(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .double(let y)), (.double(let y), .int(let x)):
            return Double(x) == y
        default:
            return a == b
        }
    }

    private struct Parser {
        private let chars: [Character]
        private var pos = 0
        private let expression: String

        init(_ expression: String) {
            self.expression = expression
            self.chars = Array(expression)
        }

        mutating func parseSteps() throws -> [Step] {
            var steps: [Step] = []
            guard !chars.isEmpty else { throw error("expression is empty") }
            while pos < chars.count {
                if chars[pos] == "[" {
                    steps.append(try parseBracket())
                } else if chars[pos] == "." {
                    pos += 1
                    guard pos < chars.count, chars[pos] != "." else {
                        throw error("expected a field name after '.'")
                    }
                } else {
                    let name = parseIdentifier()
                    guard !name.isEmpty else {
                        throw error("unexpected character '\(chars[pos])'")
                    }
                    steps.append(.field(name))
                }
            }
            return steps
        }

        private mutating func parseIdentifier() -> String {
            var name = ""
            while pos < chars.count, chars[pos] != ".", chars[pos] != "[" {
                name.append(chars[pos])
                pos += 1
            }
            return name
        }

        private mutating func parseBracket() throws -> Step {
            pos += 1  // consume '['
            guard pos < chars.count else { throw error("unterminated '['") }
            if chars[pos] == "*" {
                pos += 1
                try consume("]")
                return .wildcard
            }
            if chars[pos] == "?" {
                pos += 1
                return try parseFilter()
            }
            var digits = ""
            while pos < chars.count, chars[pos] == "-" || chars[pos].isNumber {
                digits.append(chars[pos])
                pos += 1
            }
            guard let index = Int(digits) else {
                throw error("expected *, ?, or an index inside [ ]")
            }
            try consume("]")
            return .index(index)
        }

        private mutating func parseFilter() throws -> Step {
            var path: [String] = []
            var name = ""
            while pos < chars.count, chars[pos] != "=", chars[pos] != "!" {
                if chars[pos] == "." {
                    path.append(name)
                    name = ""
                } else {
                    name.append(chars[pos])
                }
                pos += 1
            }
            path.append(name)
            guard path.allSatisfy({ !$0.isEmpty }) else {
                throw error("filter needs a field name before the comparator")
            }
            let negated: Bool
            if match("==") {
                negated = false
            } else if match("!=") {
                negated = true
            } else {
                throw error("filter supports == and != only")
            }
            let literal = try parseLiteral()
            try consume("]")
            return .filter(path: path, negated: negated, literal: literal)
        }

        private mutating func parseLiteral() throws -> JSONValue {
            guard pos < chars.count else { throw error("filter is missing a literal") }
            if chars[pos] == "'" {
                pos += 1
                var text = ""
                while pos < chars.count, chars[pos] != "'" {
                    text.append(chars[pos])
                    pos += 1
                }
                try consume("'")
                return .string(text)
            }
            var raw = ""
            while pos < chars.count, chars[pos] != "]" {
                raw.append(chars[pos])
                pos += 1
            }
            switch raw {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                if let i = Int(raw) { return .int(i) }
                if let d = Double(raw) { return .double(d) }
                throw error("literal must be 'quoted', a number, true, false, or null")
            }
        }

        private mutating func match(_ token: String) -> Bool {
            let t = Array(token)
            guard pos + t.count <= chars.count, Array(chars[pos..<pos + t.count]) == t else {
                return false
            }
            pos += t.count
            return true
        }

        private mutating func consume(_ c: Character) throws {
            guard pos < chars.count, chars[pos] == c else {
                throw error("expected '\(c)'")
            }
            pos += 1
        }

        private func error(_ reason: String) -> AppctlError {
            .invalidInput(
                field: "--query", value: expression,
                expected: "\(reason). Supported: dot paths, [N], [*], [?field=='x']")
        }
    }
}
