import Foundation

/// Builds the envelope's `next` map: action name → a literal, ready-to-run appctl
/// command, offered only when the resource's state actually permits the action.
///
/// Flags to carry into suggested commands are passed in explicitly rather than read
/// from `GlobalOptions` here, so a future profile/--team concept (G6) changes only
/// `GlobalOptions.propagatedFlags`, not every call site.
public struct NextActions: Sendable {
    private let flagSuffix: String

    public init(propagatedFlags: [String]) {
        flagSuffix =
            propagatedFlags.isEmpty
            ? "" : " " + propagatedFlags.map(Self.shellQuote).joined(separator: " ")
    }

    /// App Store version states in which the developer may edit and submit.
    public static let editableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "INVALID_BINARY",
    ]

    /// States in which the only developer action is pulling the version back out.
    public static let inReviewVersionStates: Set<String> = [
        "WAITING_FOR_REVIEW", "IN_REVIEW",
    ]

    public func command(_ words: [String]) -> String {
        (["appctl"] + words.map(Self.shellQuote)).joined(separator: " ") + flagSuffix
    }

    /// Actions for a set of versions: `submit` for the first editable version,
    /// `reject` for the first version sitting in review. Locked versions
    /// (READY_FOR_SALE, PENDING_APPLE_RELEASE, …) offer nothing.
    public func forVersions(_ versions: [(id: String, state: String?)]) -> [String: String] {
        var actions: [String: String] = [:]
        if let editable = versions.first(where: { Self.editableVersionStates.contains($0.state ?? "") }) {
            actions["submit"] = command(["versions", "submit", editable.id])
        }
        if let inReview = versions.first(where: { Self.inReviewVersionStates.contains($0.state ?? "") }) {
            actions["reject"] = command(["versions", "reject", inReview.id])
        }
        return actions
    }

    public func nextPage(url: String) -> [String: String] {
        ["nextPage": command(["api", "GET", url])]
    }

    /// Minimal POSIX-shell quoting: pass safe tokens through untouched, single-quote
    /// the rest so the suggested command survives copy-paste.
    static func shellQuote(_ token: String) -> String {
        let safe = token.allSatisfy {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || "_-./:=+@%".contains($0)
        }
        if safe, !token.isEmpty { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
