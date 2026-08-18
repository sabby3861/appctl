import Foundation
import Testing

@testable import AppctlCore

private func quietOutput() -> OutputFormatter {
    OutputFormatter(format: .json, noColor: true)
}

@Suite("Localizations set command") struct LocalizationsSetCommandTests {
    private static let localization = """
        {"data":{"type":"appStoreVersionLocalizations","id":"loc-1","attributes":{"locale":"en-US",\
        "description":"New description","keywords":"a,b"}}}
        """

    @Test func dryRunIssuesNoRequests() async throws {
        let mock = MockAppStoreConnectClient()

        let outcome = try await LocalizationsCommand.Set.execute(
            client: mock, output: quietOutput(), localizationId: "loc-1",
            appDescription: "New description", keywords: nil, whatsNew: nil,
            promotionalText: nil, dryRun: true)

        #expect(await mock.requests.isEmpty, "--dry-run must never touch the API")
        #expect(outcome == nil)
    }

    @Test func oversizedDescriptionFailsBeforeAnyRequest() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            _ = try await LocalizationsCommand.Set.execute(
                client: mock, output: quietOutput(), localizationId: "loc-1",
                appDescription: String(repeating: "x", count: 4001), keywords: nil,
                whatsNew: nil, promotionalText: nil, dryRun: false)
        }
        #expect(await mock.requests.isEmpty, "validation must fail before any request is issued")
    }

    @Test func patchesProvidedFieldsAndReturnsOutcome() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.localization)

        let outcome = try await LocalizationsCommand.Set.execute(
            client: mock, output: quietOutput(), localizationId: "loc-1",
            appDescription: "New description", keywords: "a,b", whatsNew: nil,
            promotionalText: nil, dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "appStoreVersionLocalizations/loc-1")
        let attrs = nested(try jsonObject(requests[0].body), "data", "attributes")
        #expect(attrs["description"] as? String == "New description")
        #expect(attrs["keywords"] as? String == "a,b")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "id": .string("loc-1"),
                    "locale": .string("en-US"),
                    "updated_fields": .array([.string("description"), .string("keywords")]),
                ]))
    }
}

@Suite("Localizations sync command") struct LocalizationsSyncCommandTests {
    private static let localizations = """
        {"data":[{"type":"appStoreVersionLocalizations","id":"loc-1","attributes":{"locale":"en-US",\
        "description":"Old","keywords":"old"}}]}
        """
    private static let patched = """
        {"data":{"type":"appStoreVersionLocalizations","id":"loc-1","attributes":{"locale":"en-US",\
        "description":"Fresh description"}}}
        """

    @Test func rejectsUnknownDirectionBeforeAnyRequest() async throws {
        let mock = MockAppStoreConnectClient()

        await #expect(throws: AppctlError.self) {
            _ = try await LocalizationsCommand.Sync.execute(
                client: mock, output: quietOutput(), versionId: "ver-1", dir: "./metadata",
                direction: "sideways", dryRun: false)
        }
        #expect(await mock.requests.isEmpty, "validation must fail before any request is issued")
    }

    @Test func pushPatchesEachLocaleWithLocalFilesAndReturnsOutcome() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-sync-\(UUID().uuidString)")
        let localeDir = tmp.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Fresh description\n".write(
            to: localeDir.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)

        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.localizations)
        await mock.queue(Self.patched)

        let outcome = try await LocalizationsCommand.Sync.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dir: tmp.path,
            direction: "push", dryRun: false)

        let requests = await mock.requests
        try #require(requests.count == 2)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "appStoreVersions/ver-1/appStoreVersionLocalizations")
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].path == "appStoreVersionLocalizations/loc-1")
        let attrs = nested(try jsonObject(requests[1].body), "data", "attributes")
        #expect(
            attrs["description"] as? String == "Fresh description",
            "the trailing editor newline is stripped before pushing")

        let data = try #require(outcome).data
        #expect(
            data
                == .object([
                    "direction": .string("push"),
                    "version_id": .string("ver-1"),
                    "dir": .string(tmp.path),
                    "locales": .array([.string("en-US")]),
                ]))
    }

    @Test func pushDryRunFetchesButNeverPatches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-sync-\(UUID().uuidString)")
        let localeDir = tmp.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Fresh description\n".write(
            to: localeDir.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)

        let mock = MockAppStoreConnectClient()
        await mock.queue(Self.localizations)

        let outcome = try await LocalizationsCommand.Sync.execute(
            client: mock, output: quietOutput(), versionId: "ver-1", dir: tmp.path,
            direction: "push", dryRun: true)

        let requests = await mock.requests
        #expect(requests.map(\.method) == ["GET"], "--dry-run reads but never writes")
        #expect(outcome == nil)
    }
}
