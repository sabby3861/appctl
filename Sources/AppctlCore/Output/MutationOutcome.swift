import Foundation

/// What a mutating command's execute seam produced: the mutated resource (`data`)
/// and any state-aware follow-up actions (`next`). `run()` renders it as a success
/// envelope, giving JSON-mode consumers the same versioned contract mutations as
/// reads — and giving task V9's audit log one uniform shape at every mutation site.
public struct MutationOutcome: Sendable {
    public let data: JSONValue
    public let warnings: [String]
    public let next: [String: String]?

    public init(data: JSONValue, warnings: [String] = [], next: [String: String]? = nil) {
        self.data = data
        self.warnings = warnings
        self.next = next
    }
}

extension OutputFormatter {
    /// Success output for a mutating command: the versioned envelope in JSON mode,
    /// nothing otherwise — human modes already reported success on stderr.
    public func printMutation(_ outcome: MutationOutcome) {
        guard format == .json else { return }
        printEnvelope(data: outcome.data, warnings: outcome.warnings, next: outcome.next)
    }
}
