import Foundation
import Testing

@testable import AppctlCore

/// V9 audit subsystem: the AuditingClient decorator (entry shape, snapshots,
/// failure policy), NDJSON persistence under concurrency, and credential redaction.

private let notFoundBody = #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"Not found"}]}"#

private func tempAuditDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appctl-test-\(UUID().uuidString)/audit")
}

private func auditedClient(
    wrapping mock: MockAppStoreConnectClient, command: String = "test command"
) -> (client: AuditingClient, directory: URL) {
    let directory = tempAuditDirectory()
    let client = AuditingClient(
        wrapping: mock, log: AuditLog(directory: directory), command: command)
    return (client, directory)
}

@Suite("audit — mutation recording") struct AuditingClientTests {
    private let localizationBody: JSONValue = .object([
        "data": .object([
            "type": .string("appStoreVersionLocalizations"), "id": .string("loc-1"),
            "attributes": .object(["whatsNew": .string("Bug fixes")]),
        ])
    ])

    @Test func eligiblePatchAppendsEntryWithPriorState() async throws {
        let mock = MockAppStoreConnectClient()
        let snapshotJSON =
            #"{"data":{"type":"appStoreVersionLocalizations","id":"loc-1","attributes":{"whatsNew":"old"}}}"#
        await mock.queue(snapshotJSON)
        await mock.queue(#"{"data":{"type":"appStoreVersionLocalizations","id":"loc-1"}}"#)
        let (client, directory) = auditedClient(
            wrapping: mock, command: "localizations update loc-1")

        let _: JSONValue = try await client.patch(
            "appStoreVersionLocalizations/loc-1", body: localizationBody)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "GET", "the snapshot is taken before the write")
        #expect(requests[0].path == "appStoreVersionLocalizations/loc-1")
        #expect(requests[0].queryItems == nil, "the snapshot is one plain GET — no pagination, no includes")
        #expect(requests[1].method == "PATCH")

        let (entries, malformed) = try AuditLog.readEntries(in: directory)
        #expect(malformed == 0)
        try #require(entries.count == 1, "the snapshot GET must not produce its own entry")
        let entry = entries[0]
        #expect(entry.command == "localizations update loc-1")
        #expect(entry.method == "PATCH")
        #expect(entry.endpoint == "/v1/appStoreVersionLocalizations/loc-1")
        #expect(entry.resourceType == "appStoreVersionLocalizations")
        #expect(entry.resourceId == "loc-1")
        let expectedPrior = try JSONDecoder().decode(JSONValue.self, from: Data(snapshotJSON.utf8))
        #expect(entry.priorState == expectedPrior)

        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        #expect(entry.requestDigest == AuditEntry.requestDigest(of: try canonical.encode(localizationBody)))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(formatter.date(from: entry.ts) != nil, "ts is ISO 8601 with fractional seconds")
        #expect(AuditLog.fileName(for: entry.ts) == "\(entry.ts.prefix(7)).ndjson")
    }

    @Test func ineligibleTypeSkipsSnapshot() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appStoreVersions","id":"v-1"}}"#)
        let (client, directory) = auditedClient(wrapping: mock)

        let _: JSONValue = try await client.patch(
            "appStoreVersions/v-1", body: JSONValue.object([:]))

        let requests = await mock.requests
        try #require(requests.count == 1, "no GET-before-write for non-eligible types")
        #expect(requests[0].method == "PATCH")
        let entry = try #require(try AuditLog.readEntries(in: directory).entries.first)
        #expect(entry.priorState == nil)
    }

    @Test func postRecordsCreationWithoutIdOrSnapshot() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appStoreVersions","id":"v-new"}}"#)
        let (client, directory) = auditedClient(wrapping: mock)

        let _: JSONValue = try await client.post("appStoreVersions", body: JSONValue.object([:]))

        #expect(await mock.requests.count == 1)
        let entry = try #require(try AuditLog.readEntries(in: directory).entries.first)
        #expect(entry.method == "POST")
        #expect(entry.resourceType == "appStoreVersions")
        #expect(entry.resourceId == nil, "a creation has no pre-existing resource ID")
        #expect(entry.priorState == nil)
    }

    @Test func eligibleDeleteSnapshotsAndDigestsEmptyBody() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appInfoLocalizations","id":"il-1"}}"#)
        let (client, directory) = auditedClient(wrapping: mock)

        try await client.delete("appInfoLocalizations/il-1")

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "GET")
        let entry = try #require(try AuditLog.readEntries(in: directory).entries.first)
        #expect(entry.method == "DELETE")
        #expect(entry.priorState != nil)
        #expect(entry.requestDigest == AuditEntry.requestDigest(of: Data()))
    }

    @Test func patchVoidOnRelationshipPathAttributesToParent() async throws {
        let mock = MockAppStoreConnectClient()
        let (client, directory) = auditedClient(wrapping: mock)

        try await client.patchVoid(
            "appStoreVersions/v-1/relationships/build", body: JSONValue.object([:]))

        let entry = try #require(try AuditLog.readEntries(in: directory).entries.first)
        #expect(entry.endpoint == "/v1/appStoreVersions/v-1/relationships/build")
        #expect(entry.resourceType == "appStoreVersions")
        #expect(entry.resourceId == "v-1")
        #expect(entry.priorState == nil, "relationship paths are never snapshot-shaped")
    }

    @Test func failedMutationIsNotAudited() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":{"type":"appStoreVersionLocalizations","id":"loc-1"}}"#)
        await mock.failNext(
            "PATCH", "appStoreVersionLocalizations/loc-1", withErrorBody: notFoundBody)
        let (client, directory) = auditedClient(wrapping: mock)

        await #expect(throws: AppctlError.self) {
            let _: JSONValue = try await client.patch(
                "appStoreVersionLocalizations/loc-1", body: JSONValue.object([:]))
        }
        #expect(
            !FileManager.default.fileExists(atPath: directory.path),
            "a failed call changed nothing and must not be audited")
    }

    @Test func snapshotFailureDoesNotBlockTheMutation() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.failNext(
            "GET", "appStoreVersionLocalizations/loc-1", withErrorBody: notFoundBody)
        await mock.queue(#"{"data":{"type":"appStoreVersionLocalizations","id":"loc-1"}}"#)
        let (client, directory) = auditedClient(wrapping: mock)

        let _: JSONValue = try await client.patch(
            "appStoreVersionLocalizations/loc-1", body: JSONValue.object([:]))

        let entry = try #require(try AuditLog.readEntries(in: directory).entries.first)
        #expect(entry.method == "PATCH")
        #expect(entry.priorState == nil, "the entry is still written, just without a snapshot")
    }
}

@Suite("audit — path analysis") struct AuditPathTests {
    @Test func absoluteVersionedURLsParse() {
        let parsed = AuditingClient.parse(
            path: "https://api.appstoreconnect.apple.com/v2/appAvailabilities/av-1?fields=x")
        #expect(parsed.endpoint == "/v2/appAvailabilities/av-1?fields=x")
        #expect(parsed.resourceType == "appAvailabilities")
        #expect(parsed.resourceId == "av-1")
        #expect(
            parsed.snapshotPath == "https://api.appstoreconnect.apple.com/v2/appAvailabilities/av-1",
            "the snapshot keeps the mutation's absolute form, minus the query")
    }

    @Test func relativePathsNormalizeToV1() {
        let parsed = AuditingClient.parse(path: "territoryAvailabilities/t-1")
        #expect(parsed.endpoint == "/v1/territoryAvailabilities/t-1")
        #expect(parsed.snapshotPath == "territoryAvailabilities/t-1")

        let collection = AuditingClient.parse(path: "appStoreVersions")
        #expect(collection.resourceType == "appStoreVersions")
        #expect(collection.resourceId == nil)
        #expect(collection.snapshotPath == nil)
    }
}

@Suite("audit — log file") struct AuditLogTests {
    private func entry(ts: String, command: String = "test") -> AuditEntry {
        AuditEntry(
            ts: ts, command: command, endpoint: "/v1/apps/1", method: "PATCH",
            resourceType: "apps", resourceId: "1",
            requestDigest: AuditEntry.requestDigest(of: Data()), priorState: nil)
    }

    @Test func groupsEntriesIntoMonthlyFiles() async throws {
        let directory = tempAuditDirectory()
        let log = AuditLog(directory: directory)
        try await log.append(entry(ts: "2026-07-31T23:59:59.000Z"))
        try await log.append(entry(ts: "2026-08-01T00:00:00.000Z"))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["2026-07.ndjson", "2026-08.ndjson"])
        let (entries, malformed) = try AuditLog.readEntries(in: directory)
        #expect(entries.count == 2)
        #expect(malformed == 0)
    }

    @Test func survivesConcurrentAppends() async throws {
        let directory = tempAuditDirectory()
        // Two independent AuditLog instances stand in for two appctl processes:
        // nothing shared but the O_APPEND file descriptor semantics.
        let logs = [AuditLog(directory: directory), AuditLog(directory: directory)]
        let total = 100

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    try await logs[i % logs.count].append(
                        entry(ts: "2026-08-18T12:00:00.000Z", command: "writer \(i)"))
                }
            }
            try await group.waitForAll()
        }

        let (entries, malformed) = try AuditLog.readEntries(in: directory)
        #expect(malformed == 0, "concurrent appends must interleave whole lines")
        #expect(entries.count == total)
        #expect(Set(entries.map(\.command)).count == total, "every writer's line survives intact")
    }
}

@Suite("audit — credential redaction") struct AuditRedactionTests {
    @Test func redactsCredentialFlagValuesInBothForms() {
        let separate = AuditEntry.redactedCommand(arguments: [
            "versions", "update", "v-1", "--key-id", "ABC123", "--issuer-id", "iss-1",
        ])
        #expect(separate == "versions update v-1 --key-id <redacted> --issuer-id <redacted>")

        let equals = AuditEntry.redactedCommand(arguments: [
            "apps", "list", "--key-id=ABC123", "--private-key-path=/keys/AuthKey_ABC.p8",
        ])
        #expect(equals == "apps list --key-id=<redacted> --private-key-path=<redacted>")
    }

    @Test func redactsStrayKeyMaterialAnywhere() {
        let p8 = AuditEntry.redactedCommand(arguments: [
            "migrate", "--from-fastlane", "/Users/me/secrets/AuthKey_XYZ.p8",
        ])
        #expect(
            p8 == "migrate --from-fastlane <redacted>/AuthKey_XYZ.p8",
            "a positional .p8 path keeps only its filename")

        let pem = AuditEntry.redactedCommand(arguments: [
            "auth", "-----BEGIN PRIVATE KEY-----abc-----END PRIVATE KEY-----",
        ])
        #expect(pem == "auth <redacted>")
    }

    @Test func ordinaryArgumentsPassThrough() {
        let plain = AuditEntry.redactedCommand(arguments: ["versions", "create", "--version", "1.2.3"])
        #expect(plain == "versions create --version 1.2.3")
    }
}
