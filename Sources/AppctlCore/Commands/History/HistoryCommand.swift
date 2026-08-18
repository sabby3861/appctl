import ArgumentParser
import Foundation

/// `appctl history` — reads the append-only audit log back. Local and read-only:
/// no client, no network, and (not being a mutation) no audit entry of its own.
public struct HistoryCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the audit log of mutating operations.",
        discussion: """
            Every mutating appctl command appends one entry to
            ~/.appctl/audit/<year-month>.ndjson. JSON output carries the full
            entries (including priorState snapshots); table output summarizes.
            """)

    @Option(name: .long, help: "Only entries mentioning this app ID.")
    var appId: String?
    @Option(
        name: .long,
        help: ArgumentHelp("Only entries newer than a window like 7d, 24h, or 30m.", valueName: "window"))
    var since: String?
    @OptionGroup var globals: GlobalOptions

    public init() {}

    public func run() async throws {
        let output = try globals.outputFormatter()
        let result = try Self.execute(
            directory: AuditLog.defaultDirectory, appId: appId, since: since, now: Date())

        if output.format == .json {
            // Full fidelity: re-encode the typed entries rather than flattening to
            // table columns, so priorState and requestDigest survive into `data`.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(result.entries))
            output.printEnvelope(data: data, warnings: result.warnings)
            return
        }
        for warning in result.warnings { output.warning(warning) }
        output.printList(
            result.entries,
            columns: [
                Column<AuditEntry>(header: "Timestamp") { String($0.ts.prefix(19)) },
                Column(header: "Method") { $0.method },
                Column(header: "Resource") { entry in
                    entry.resourceId.map { "\(entry.resourceType)/\($0)" } ?? entry.resourceType
                },
                Column(header: "Command") { $0.command },
            ],
            emptyMessage: "No audited mutations found.")
    }

    static func execute(
        directory: URL, appId: String?, since: String?, now: Date
    ) throws -> (entries: [AuditEntry], warnings: [String]) {
        let cutoff = try since.map { now.addingTimeInterval(-(try window(parsing: $0))) }
        let (all, malformed) = try AuditLog.readEntries(in: directory)
        var entries = all
        if let cutoff {
            entries = entries.filter { (parseTimestamp($0.ts) ?? .distantPast) >= cutoff }
        }
        if let appId {
            // The schema has no appId field (many endpoints never mention the app),
            // so the filter matches wherever the ID can surface: the redacted
            // command line, the endpoint path, or the resource itself.
            entries = entries.filter {
                $0.command.contains(appId) || $0.endpoint.contains(appId) || $0.resourceId == appId
            }
        }
        entries.sort { $0.ts > $1.ts }
        let warnings =
            malformed > 0 ? ["Skipped \(malformed) malformed audit line(s) in \(directory.path)."] : []
        return (entries, warnings)
    }

    static func window(parsing raw: String) throws -> TimeInterval {
        let secondsPerUnit: [Character: TimeInterval] = ["d": 86400, "h": 3600, "m": 60]
        guard raw.count >= 2, let unit = raw.last, let seconds = secondsPerUnit[unit],
            let count = Int(raw.dropLast()), count > 0
        else {
            throw AppctlError.invalidInput(
                field: "--since", value: raw, expected: "A positive window like 7d, 24h, or 30m")
        }
        return TimeInterval(count) * seconds
    }

    private static func parseTimestamp(_ ts: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: ts) { return date }
        // Our writer always emits fractional seconds; whole-second timestamps can
        // only come from hand-edited or foreign lines — still worth honoring.
        return ISO8601DateFormatter().date(from: ts)
    }
}
