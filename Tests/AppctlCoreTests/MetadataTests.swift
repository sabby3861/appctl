import Foundation
import Testing

@testable import AppctlCore

/// Metadata pull/push acceptance tests: fastlane file layout, byte-identical
/// round-trips, the subset ("ignored (unsupported)") policy, and localization
/// creation for new locales.

private func quietOutput() -> OutputFormatter {
    OutputFormatter(format: .json, noColor: true)
}

private let versionListResponse = """
    {"data":[{"type":"appStoreVersions","id":"VER-1","attributes":{"versionString":"2.1.0"}}]}
    """

/// A description spanning multiple lines exercises the round-trip contract harder
/// than a single-line value: only the one appended trailing newline may be stripped.
private let descriptionValue = "Line one.\nLine two — with unicode ✓."
private let keywordsValue = "swift,cli,appstore"
private let whatsNewValue = "Fixed a crash.\nFaster uploads."
private let promotionalValue = "The Swift CLI for App Store Connect."
private let marketingURLValue = "https://example.com/appctl"
private let supportURLValue = "https://example.com/support"

private func localizationListResponse() throws -> String {
    let attributes: [String: String] = [
        "locale": "en-US",
        "description": descriptionValue,
        "keywords": keywordsValue,
        "whatsNew": whatsNewValue,
        "promotionalText": promotionalValue,
        "marketingUrl": marketingURLValue,
        "supportUrl": supportURLValue,
    ]
    let attributesJSON = String(
        data: try JSONSerialization.data(withJSONObject: attributes), encoding: .utf8)!
    return """
        {"data":[{"type":"appStoreVersionLocalizations","id":"LOC-1",\
        "attributes":\(attributesJSON)}]}
        """
}

private let patchResponse = """
    {"data":{"type":"appStoreVersionLocalizations","id":"LOC-1",\
    "attributes":{"locale":"en-US"}}}
    """

@Suite("Metadata pull/push") struct MetadataTests {

    @Test func pullWritesFastlaneFilesWithOneTrailingNewline() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(try localizationListResponse())

        try await MetadataCommand.Pull.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0", path: dir.path,
            dryRun: false)

        let locale = dir.appendingPathComponent("en-US")
        func contents(_ name: String) throws -> String {
            try String(contentsOf: locale.appendingPathComponent(name), encoding: .utf8)
        }
        #expect(try contents("description.txt") == descriptionValue + "\n")
        #expect(try contents("keywords.txt") == keywordsValue + "\n")
        #expect(try contents("release_notes.txt") == whatsNewValue + "\n")
        #expect(try contents("promotional_text.txt") == promotionalValue + "\n")
        #expect(try contents("marketing_url.txt") == marketingURLValue + "\n")
        #expect(try contents("support_url.txt") == supportURLValue + "\n")
    }

    @Test func pullDryRunWritesNothing() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(try localizationListResponse())

        try await MetadataCommand.Pull.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0", path: dir.path,
            dryRun: true)

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func pullThenPushRoundTripsByteIdentical() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pullMock = MockAppStoreConnectClient()
        await pullMock.queue(versionListResponse)
        await pullMock.queue(try localizationListResponse())
        try await MetadataCommand.Pull.execute(
            client: pullMock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false)

        let pushMock = MockAppStoreConnectClient()
        await pushMock.queue(versionListResponse)
        await pushMock.queue(try localizationListResponse())
        await pushMock.queue(patchResponse)
        let summary = try await MetadataCommand.Push.execute(
            client: pushMock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false)

        #expect(summary.pushed == ["en-US"])
        let requests = await pushMock.requests
        let patch = try #require(requests.first { $0.method == "PATCH" })
        #expect(patch.path == "appStoreVersionLocalizations/LOC-1")
        let attributes = nested(try jsonObject(patch.body), "data", "attributes")
        #expect(attributes["description"] as? String == descriptionValue)
        #expect(attributes["keywords"] as? String == keywordsValue)
        #expect(attributes["whatsNew"] as? String == whatsNewValue)
        #expect(attributes["promotionalText"] as? String == promotionalValue)
        #expect(attributes["marketingUrl"] as? String == marketingURLValue)
        #expect(attributes["supportUrl"] as? String == supportURLValue)
    }

    @Test func pushReportsUnknownFilesAsIgnoredNeverSilent() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try "A description.\n".write(
            to: locale.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)
        try "mystery".write(
            to: locale.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try "stray".write(
            to: dir.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(try localizationListResponse())

        let summary = try await MetadataCommand.Push.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: true)

        #expect(summary.ignored.contains("en-US/extra.txt"))
        #expect(summary.ignored.contains("stray.txt"))
        // Dry run: reads only, no mutations.
        let requests = await mock.requests
        #expect(requests.allSatisfy { $0.method == "GET" })
    }

    @Test func pushCreatesMissingLocalization() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("de-DE")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try "Eine Beschreibung.\n".write(
            to: locale.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(try localizationListResponse())  // only en-US exists
        await mock.queue(
            """
            {"data":{"type":"appStoreVersionLocalizations","id":"LOC-2",\
            "attributes":{"locale":"de-DE"}}}
            """)

        let summary = try await MetadataCommand.Push.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false)

        #expect(summary.created == ["de-DE"])
        let requests = await mock.requests
        let post = try #require(requests.first { $0.method == "POST" })
        #expect(post.path == "appStoreVersionLocalizations")
        let body = try jsonObject(post.body)
        #expect(nested(body, "data", "attributes")["locale"] as? String == "de-DE")
        #expect(nested(body, "data", "attributes")["description"] as? String == "Eine Beschreibung.")
        #expect(
            nested(body, "data", "relationships", "appStoreVersion", "data")["id"] as? String
                == "VER-1")
    }

    @Test func pushValidatesCharacterLimitsBeforeAnyNetworkCall() async throws {
        let dir = try makeTempDir("metadata")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try String(repeating: "x", count: 101).write(
            to: locale.appendingPathComponent("keywords.txt"), atomically: true, encoding: .utf8)

        let mock = MockAppStoreConnectClient()
        await #expect(throws: AppctlError.self) {
            _ = try await MetadataCommand.Push.execute(
                client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
                path: dir.path, dryRun: false)
        }
        let requests = await mock.requests
        #expect(requests.isEmpty)
    }
}
