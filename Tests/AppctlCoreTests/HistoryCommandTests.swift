import Foundation
import Testing

@testable import AppctlCore

/// `appctl history` seam tests: window parsing, --since and --app-id filters,
/// ordering, and malformed-line tolerance.

@Suite("history command") struct HistoryCommandTests {
    private let now = ISO8601DateFormatter().date(from: "2026-08-18T12:00:00Z")!

    private func entry(
        ts: String, command: String = "test", endpoint: String = "/v1/apps/1",
        resourceId: String? = "1"
    ) -> AuditEntry {
        AuditEntry(
            ts: ts, command: command, endpoint: endpoint, method: "PATCH",
            resourceType: "apps", resourceId: resourceId,
            requestDigest: AuditEntry.requestDigest(of: Data()), priorState: nil)
    }

    private func makeLog() -> (log: AuditLog, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-test-\(UUID().uuidString)/audit")
        return (AuditLog(directory: directory), directory)
    }

    @Test func sinceFilterKeepsOnlyRecentEntries() async throws {
        let (log, directory) = makeLog()
        try await log.append(entry(ts: "2026-08-18T11:00:00.000Z", command: "recent"))
        try await log.append(entry(ts: "2026-08-01T11:00:00.000Z", command: "old"))

        let result = try HistoryCommand.execute(
            directory: directory, appId: nil, since: "7d", now: now)
        #expect(result.entries.map(\.command) == ["recent"])

        let all = try HistoryCommand.execute(
            directory: directory, appId: nil, since: nil, now: now)
        #expect(all.entries.count == 2)
        #expect(
            all.entries.map(\.command) == ["recent", "old"],
            "entries are newest-first")
    }

    @Test func appIdFilterMatchesCommandEndpointAndResource() async throws {
        let (log, directory) = makeLog()
        try await log.append(
            entry(ts: "2026-08-18T10:00:00.000Z", command: "versions create --app-id 6448")
        )
        try await log.append(
            entry(
                ts: "2026-08-18T10:01:00.000Z", command: "metadata push",
                endpoint: "/v1/apps/6448/appInfos", resourceId: nil))
        try await log.append(
            entry(
                ts: "2026-08-18T10:02:00.000Z", command: "api PATCH",
                endpoint: "/v1/apps/6448", resourceId: "6448"))
        try await log.append(
            entry(
                ts: "2026-08-18T10:03:00.000Z", command: "unrelated",
                endpoint: "/v1/betaGroups/g-1", resourceId: "g-1"))

        let result = try HistoryCommand.execute(
            directory: directory, appId: "6448", since: nil, now: now)
        #expect(result.entries.count == 3)
        #expect(!result.entries.contains { $0.command == "unrelated" })
    }

    @Test func malformedLinesAreCountedNotFatal() async throws {
        let (log, directory) = makeLog()
        try await log.append(entry(ts: "2026-08-18T10:00:00.000Z"))
        let file = directory.appendingPathComponent("2026-08.ndjson")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()

        let result = try HistoryCommand.execute(
            directory: directory, appId: nil, since: nil, now: now)
        #expect(result.entries.count == 1)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("1 malformed"))
    }

    @Test func missingLogDirectoryMeansEmptyHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-test-\(UUID().uuidString)/never-created")
        let result = try HistoryCommand.execute(
            directory: directory, appId: nil, since: nil, now: now)
        #expect(result.entries.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func windowParsing() throws {
        #expect(try HistoryCommand.window(parsing: "7d") == 7 * 86400)
        #expect(try HistoryCommand.window(parsing: "24h") == 24 * 3600)
        #expect(try HistoryCommand.window(parsing: "30m") == 30 * 60)
        #expect(throws: AppctlError.self) { _ = try HistoryCommand.window(parsing: "7") }
        #expect(throws: AppctlError.self) { _ = try HistoryCommand.window(parsing: "d") }
        #expect(throws: AppctlError.self) { _ = try HistoryCommand.window(parsing: "0d") }
        #expect(throws: AppctlError.self) { _ = try HistoryCommand.window(parsing: "7w") }
        #expect(throws: AppctlError.self) { _ = try HistoryCommand.window(parsing: "-1h") }
    }
}
