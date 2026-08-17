import Foundation

/// Line-based parsers for fastlane's Ruby configuration files (Appfile,
/// Deliverfile, Fastfile). Ruby is never executed: only literal top-level
/// assignments are read, in the spirit of `ConfigLoader.parseTOML`'s deliberate
/// subset. Anything dynamic — `ENV[...]`, conditionals, blocks — is surfaced as
/// a warning instead of being guessed at.
enum FastlaneParsers {
    struct ParsedFile: Sendable, Equatable {
        var values: [String: String] = [:]
        var warnings: [String] = []
    }

    /// Keys an Appfile can meaningfully carry.
    static let appfileKeys: Set<String> = ["app_identifier", "apple_id", "team_id", "itc_team_id"]

    /// Extracts literal `key "value"` assignments for the given keys.
    /// `keys: nil` accepts any `identifier value` line (Deliverfile mode).
    /// Handles both quote styles, optional parentheses, and bare
    /// booleans/numbers. Lines inside `if`/`unless`/`case`/`for_platform`/
    /// `for_lane`/`do` blocks are skipped with one warning per block; lines
    /// whose value involves `ENV[` warn instead of producing a value.
    static func parse(_ content: String, fileName: String, keys: Set<String>? = nil) -> ParsedFile {
        var result = ParsedFile()
        var blockDepth = 0
        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if blockDepth > 0 {
                if opensBlock(line) { blockDepth += 1 } else if line == "end" { blockDepth -= 1 }
                continue
            }
            if opensBlock(line) {
                blockDepth += 1
                result.warnings.append(
                    "\(fileName):\(lineNumber): conditional or block line ignored — "
                        + "appctl migrate reads only top-level literal values; review it manually: \(line)")
                continue
            }
            guard let match = line.firstMatch(of: #/^([a-z_][a-z0-9_]*)\s*(.*)$/#) else { continue }
            let key = String(match.1)
            if let keys, !keys.contains(key) { continue }
            let rest = String(match.2)
            if rest.contains("ENV[") || rest.contains("ENV.fetch") {
                result.warnings.append(
                    "\(fileName):\(lineNumber): \(key) is set from ENV — "
                        + "appctl cannot resolve it; fill the value in manually: \(line)")
                continue
            }
            if let quoted = rest.firstMatch(of: #/^\(?\s*=?\s*["']([^"']*)["']/#) {
                result.values[key] = String(quoted.1)
            } else if let bare = rest.firstMatch(of: #/^\(?\s*=?\s*(true|false|[0-9][0-9._]*)\s*\)?\s*(?:#.*)?$/#) {
                result.values[key] = String(bare.1)
            } else if keys != nil || !rest.isEmpty {
                result.warnings.append(
                    "\(fileName):\(lineNumber): could not read a literal value for \(key) — "
                        + "review it manually: \(line)")
            }
        }
        return result
    }

    private static func opensBlock(_ line: String) -> Bool {
        if line.hasPrefix("if ") || line.hasPrefix("unless ") || line.hasPrefix("case ")
            || line.hasPrefix("for_platform") || line.hasPrefix("for_lane")
            || line.hasPrefix("def ") || line.hasPrefix("platform ") || line.hasPrefix("lane ")
        {
            return true
        }
        return line.hasSuffix(" do") || line.contains(" do |")
    }

    /// fastlane actions `appctl migrate` knows how to talk about. Order is the
    /// report order.
    enum FastfileAction: String, CaseIterable, Sendable {
        case deliver
        case uploadToAppStore = "upload_to_app_store"
        case pilot
        case uploadToTestflight = "upload_to_testflight"
        case gym
        case appStoreConnectAPIKey = "app_store_connect_api_key"
        case match
    }

    struct FastfileFinding: Sendable, Equatable {
        let action: FastfileAction
        let lineNumber: Int
    }

    /// Scans a Fastfile for known action invocations. Purely lexical: comment
    /// lines are skipped, each action is reported once at its first occurrence.
    /// Fastfiles are full Ruby programs, so unlike `parse` this never extracts
    /// values — it only detects which actions the lanes use.
    static func scanFastfile(_ content: String) -> [FastfileFinding] {
        var firstSeen: [FastfileAction: Int] = [:]
        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for action in FastfileAction.allCases where firstSeen[action] == nil {
                let pattern = "(?<![A-Za-z0-9_])\(action.rawValue)(?![A-Za-z0-9_])"
                if line.range(of: pattern, options: .regularExpression) != nil {
                    firstSeen[action] = index + 1
                }
            }
        }
        return FastfileAction.allCases.compactMap { action in
            firstSeen[action].map { FastfileFinding(action: action, lineNumber: $0) }
        }
    }
}
