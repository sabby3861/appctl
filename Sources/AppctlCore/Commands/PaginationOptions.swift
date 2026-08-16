import ArgumentParser
import Foundation

/// Shared `--limit` / `--page-size` flags for list commands that paginate. Validation
/// happens via `validated()` at execution time rather than ArgumentParser's `validate()`
/// so failures go through the What/Why/Fix formatter with a stable error code.
struct PaginationOptions: ParsableArguments {
    @Option(name: .long, help: "Maximum total results (default: all).") var limit: Int?
    @Option(name: .long, help: "Results per page, between 1 and 200.") var pageSize: Int = 200
    init() {}

    func validated() throws -> (limit: Int?, pageSize: Int) {
        try Self.validate(limit: limit, pageSize: pageSize)
        return (limit, pageSize)
    }

    static func validate(limit: Int?, pageSize: Int) throws {
        if let limit, limit < 1 {
            throw AppctlError.invalidInput(
                field: "--limit", value: String(limit), expected: "An integer of 1 or more")
        }
        guard (1...200).contains(pageSize) else {
            throw AppctlError.invalidInput(
                field: "--page-size", value: String(pageSize), expected: "An integer between 1 and 200")
        }
    }
}
