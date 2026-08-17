import Foundation
import Testing

@testable import AppctlCore

@Suite("appctl init") struct InitCommandTests {
    private let quiet = OutputFormatter(noColor: true, quiet: true)

    // MARK: Appfile parsing

    @Test func parsesAppIdentifierDoubleQuoted() {
        let content = """
            app_identifier "com.example.app" # bundle id
            apple_id "me@example.com"
            """
        #expect(InitCommand.parseAppfile(content) == "com.example.app")
    }

    @Test func parsesAppIdentifierSingleQuotedWithParens() {
        #expect(InitCommand.parseAppfile("app_identifier('com.example.app')") == "com.example.app")
    }

    @Test func skipsEnvBackedAndCommentedAppIdentifiers() {
        #expect(InitCommand.parseAppfile(#"app_identifier ENV["APP_ID"]"#) == nil)
        #expect(InitCommand.parseAppfile(#"# app_identifier "com.commented.out""#) == nil)
    }

    // MARK: Discovery precedence

    @Test func flagBeatsEnvironmentAndFile() {
        let d = InitCommand.discover(
            keyIDFlag: "FLAG", issuerIDFlag: nil, privateKeyPathFlag: nil,
            environment: ["APPCTL_KEY_ID": "ENV", "APP_STORE_CONNECT_API_KEY_KEY_ID": "FASTLANE"],
            existing: ["auth.key_id": "FILE"], appfile: nil)
        #expect(d.keyID == InitCommand.SourcedValue(value: "FLAG", source: "--key-id"))
    }

    @Test func fastlaneEnvironmentIsDiscovered() {
        let d = InitCommand.discover(
            keyIDFlag: nil, issuerIDFlag: nil, privateKeyPathFlag: nil,
            environment: [
                "APP_STORE_CONNECT_API_KEY_KEY_ID": "FL_KEY",
                "APP_STORE_CONNECT_API_KEY_ISSUER_ID": "FL_ISSUER",
                "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH": "/keys/AuthKey.p8",
            ],
            existing: [:], appfile: nil)
        #expect(d.keyID?.value == "FL_KEY")
        #expect(d.keyID?.source == "APP_STORE_CONNECT_API_KEY_KEY_ID")
        #expect(d.issuerID?.value == "FL_ISSUER")
        #expect(d.privateKeyPath?.value == "/keys/AuthKey.p8")
    }

    @Test func appctlEnvironmentBeatsFastlaneEnvironment() {
        let d = InitCommand.discover(
            keyIDFlag: nil, issuerIDFlag: nil, privateKeyPathFlag: nil,
            environment: [
                "APPCTL_KEY_ID": "APPCTL", "APP_STORE_CONNECT_API_KEY_KEY_ID": "FASTLANE",
            ],
            existing: [:], appfile: nil)
        #expect(d.keyID?.value == "APPCTL")
    }

    @Test func existingConfigWinsOverAppfileForBundleID() {
        let d = InitCommand.discover(
            keyIDFlag: nil, issuerIDFlag: nil, privateKeyPathFlag: nil,
            environment: [:],
            existing: ["auth.key_id": "FILE", "app.bundle_id": "com.file.app"],
            appfile: "app_identifier \"com.appfile.app\"")
        #expect(d.keyID?.value == "FILE")
        #expect(d.bundleID == InitCommand.SourcedValue(value: "com.file.app", source: ".appctl.toml"))
    }

    @Test func appfileSuppliesBundleIDWhenConfigHasNone() {
        let d = InitCommand.discover(
            keyIDFlag: nil, issuerIDFlag: nil, privateKeyPathFlag: nil,
            environment: [:], existing: [:], appfile: "app_identifier \"com.appfile.app\"")
        #expect(d.bundleID == InitCommand.SourcedValue(value: "com.appfile.app", source: "fastlane Appfile"))
    }

    // MARK: Merge semantics and rendering

    @Test func mergeKeepsUnrelatedKeysAndUpdatesAuth() {
        let values = InitCommand.fileValues(
            existing: ["output.format": "json", "auth.key_id": "OLD", "network.timeout": "60"],
            keyID: "NEW", issuerID: "ISS", keyPath: "~/k.p8", bundleID: nil, useKeychain: false)
        #expect(values["output.format"] == "json")
        #expect(values["network.timeout"] == "60")
        #expect(values["auth.key_id"] == "NEW")
        #expect(values["auth.issuer_id"] == "ISS")
        #expect(values["auth.private_key_path"] == "~/k.p8")
    }

    @Test func keychainModeOmitsAuthKeysFromTheFile() {
        let values = InitCommand.fileValues(
            existing: ["auth.key_id": "OLD", "auth.private_key_path": "/old.p8", "output.format": "json"],
            keyID: "NEW", issuerID: "ISS", keyPath: "/k.p8", bundleID: "com.x.y", useKeychain: true)
        #expect(values["auth.key_id"] == nil)
        #expect(values["auth.issuer_id"] == nil)
        #expect(values["auth.private_key_path"] == nil)
        #expect(values["app.bundle_id"] == "com.x.y")
        #expect(values["output.format"] == "json")
    }

    @Test func renderedTOMLRoundTripsThroughTheParser() {
        let values = [
            "auth.key_id": "ABC123",
            "auth.issuer_id": "57246542-96fe-1a63-e053-0824d011072a",
            "auth.private_key_path": "~/keys/AuthKey.p8",
            "app.bundle_id": "com.example.app",
            "output.verbose": "false",
            "network.timeout": "30",
        ]
        #expect(ConfigLoader.parseTOML(ConfigWriter.renderTOML(values)) == values)
    }

    @Test func renderOrdersKnownSectionsCanonically() throws {
        let rendered = ConfigWriter.renderTOML(["network.timeout": "30", "auth.key_id": "A"])
        let auth = try #require(rendered.range(of: "[auth]"))
        let network = try #require(rendered.range(of: "[network]"))
        #expect(auth.lowerBound < network.lowerBound)
        #expect(rendered == ConfigWriter.renderTOML(["auth.key_id": "A", "network.timeout": "30"]))
    }

    // MARK: Live validation

    @Test func validateLiveRequestsOneAppViaAppsEndpoint() async throws {
        let client = MockAppStoreConnectClient()
        await client.queue(
            """
            {"data":[{"type":"apps","id":"6448401697",
                      "attributes":{"name":"Demo","bundleId":"com.demo.app"}}],
             "meta":{"paging":{"total":4,"limit":1}}}
            """)
        try await InitCommand.validateLive(client: client, output: quiet)
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "apps")
        #expect(requests[0].queryItems?.first { $0.name == "limit" }?.value == "1")
    }

    @Test func forbidden403SurfacesTheAgreementsHint() async throws {
        let client = MockAppStoreConnectClient()
        await client.failNext(
            "GET", "apps",
            withErrorBody: """
                {"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"Forbidden",
                            "detail":"The request is not authorized."}]}
                """)
        do {
            try await InitCommand.validateLive(client: client, output: quiet)
            Issue.record("Expected a 403 to throw")
        } catch let error as AppctlError {
            #expect(error.errorCode == .authAgreementPending)
            #expect(
                error.diagnosticMessage.contains(
                    "the Account Holder may need to accept updated agreements in App Store Connect"))
        }
    }

    @Test func bare403WithoutJSONAPIBodyAlsoRefines() {
        let refined = InitCommand.refineForbidden(
            AppctlError.requestFailed(
                url: "https://api.appstoreconnect.apple.com/v1/apps", statusCode: 403, body: "<html>"))
        #expect((refined as? AppctlError)?.errorCode == .authAgreementPending)
    }

    @Test func unauthorized401IsNotRewritten() {
        let refined = InitCommand.refineForbidden(
            AppctlError.requestFailed(url: "u", statusCode: 401, body: nil))
        #expect((refined as? AppctlError)?.errorCode == .apiRequestFailed)
    }

    @Test func nonHTTPErrorsPassThroughUntouched() {
        let refined = InitCommand.refineForbidden(
            AppctlError.timeout(url: "u", duration: 30))
        #expect((refined as? AppctlError)?.errorCode == .networkTimeout)
    }

    // MARK: Writing and backup

    @Test func writeConfigBacksUpTheExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-init-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".appctl.toml").path
        try "# hand written\n[auth]\nkey_id = \"OLD\"\n".write(
            toFile: path, atomically: true, encoding: .utf8)

        let backup = try ConfigWriter.writeConfig("[auth]\nkey_id = \"NEW\"\n", to: path, output: quiet)

        #expect(backup == path + ".bak")
        #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8).contains("OLD"))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("NEW"))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func writeConfigWithoutExistingFileWritesNoBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-init-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".appctl.toml").path

        let backup = try ConfigWriter.writeConfig("[auth]\nkey_id = \"NEW\"\n", to: path, output: quiet)

        #expect(backup == nil)
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    // MARK: Dry run

    /// Pins the stdout contract: the dry-run TOML preview is written to the
    /// injected (stderr) stream, never stdout, so `--output json` keeps stdout
    /// a single valid JSON document.
    @Test func dryRunPreviewWritesTheTOMLToTheStderrStream() {
        var captured = ""
        InitCommand.printDryRun(
            rendered: "[auth]\nkey_id = \"A\"\n", configPath: ".appctl.toml",
            exists: true, useKeychain: true, keychainService: "svc",
            output: quiet, stream: &captured)
        #expect(captured == "[auth]\nkey_id = \"A\"\n")
    }

    // MARK: Non-interactive behavior

    @Test func nonInteractiveMissingValueFailsInsteadOfPrompting() {
        #expect(throws: AppctlError.self) {
            try InitCommand.require(
                nil, label: "API Key ID", flag: "--key-id", envVar: "APPCTL_KEY_ID",
                interactive: false, output: quiet)
        }
    }

    @Test func discoveredValueIsUsedWithoutPrompting() throws {
        let value = try InitCommand.require(
            InitCommand.SourcedValue(value: "ABC", source: "APPCTL_KEY_ID"),
            label: "API Key ID", flag: "--key-id", envVar: "APPCTL_KEY_ID",
            interactive: false, output: quiet)
        #expect(value == "ABC")
    }
}
