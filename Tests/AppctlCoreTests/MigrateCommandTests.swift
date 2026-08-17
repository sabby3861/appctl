import Foundation
import Testing

@testable import AppctlCore

@Suite("appctl migrate --from-fastlane") struct MigrateCommandTests {
    private let quiet = OutputFormatter(noColor: true, quiet: true)

    private func makeTempProject(_ files: [String: String], directories: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appctl-migrate-tests-\(UUID().uuidString)")
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (name, content) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: Appfile parsing

    @Test func parsesAllFourAppfileKeysWithBothQuoteStyles() {
        let parsed = FastlaneParsers.parse(
            """
            app_identifier "com.example.app" # the bundle id
            apple_id 'dev@example.com'
            team_id("ABCDE12345")
            itc_team_id '123456789'
            """,
            fileName: "Appfile", keys: FastlaneParsers.appfileKeys)
        #expect(parsed.values["app_identifier"] == "com.example.app")
        #expect(parsed.values["apple_id"] == "dev@example.com")
        #expect(parsed.values["team_id"] == "ABCDE12345")
        #expect(parsed.values["itc_team_id"] == "123456789")
        #expect(parsed.warnings.isEmpty)
    }

    @Test func envBackedAppfileLinesWarnInsteadOfProducingValues() {
        let parsed = FastlaneParsers.parse(
            #"""
            app_identifier ENV["APP_ID"]
            apple_id ENV.fetch("FASTLANE_USER")
            team_id "ABCDE12345"
            """#,
            fileName: "Appfile", keys: FastlaneParsers.appfileKeys)
        #expect(parsed.values["app_identifier"] == nil)
        #expect(parsed.values["apple_id"] == nil)
        #expect(parsed.values["team_id"] == "ABCDE12345")
        #expect(parsed.warnings.count == 2)
        #expect(parsed.warnings[0].contains("Appfile:1"))
        #expect(parsed.warnings[0].contains("ENV"))
    }

    @Test func conditionalBlocksAreSkippedWithOneWarning() {
        let parsed = FastlaneParsers.parse(
            """
            for_platform :ios do
              app_identifier "com.scoped.app"
            end
            app_identifier "com.top.app"
            """,
            fileName: "Appfile", keys: FastlaneParsers.appfileKeys)
        #expect(parsed.values["app_identifier"] == "com.top.app")
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("conditional or block"))
    }

    @Test func commentedLinesAreIgnored() {
        let parsed = FastlaneParsers.parse(
            #"# app_identifier "com.commented.out""#,
            fileName: "Appfile", keys: FastlaneParsers.appfileKeys)
        #expect(parsed.values.isEmpty)
        #expect(parsed.warnings.isEmpty)
    }

    // MARK: Deliverfile parsing

    @Test func deliverfileParsesStringsBooleansAndNumbers() {
        let parsed = FastlaneParsers.parse(
            """
            app_identifier "com.example.app"
            submit_for_review true
            copyright "2026 Example Inc."
            price_tier 0
            metadata_path "./fastlane/metadata"
            """,
            fileName: "Deliverfile")
        #expect(parsed.values["app_identifier"] == "com.example.app")
        #expect(parsed.values["submit_for_review"] == "true")
        #expect(parsed.values["copyright"] == "2026 Example Inc.")
        #expect(parsed.values["price_tier"] == "0")
        #expect(parsed.values["metadata_path"] == "./fastlane/metadata")
    }

    // MARK: Fastfile scanning

    @Test func fastfileScanFindsEachKnownActionOnce() {
        let findings = FastlaneParsers.scanFastfile(
            """
            default_platform(:ios)
            platform :ios do
              lane :release do
                app_store_connect_api_key(key_id: "ABC")
                gym(scheme: "App")
                deliver(force: true)
                deliver
              end
              lane :beta do
                match(type: "appstore")
                pilot
                # upload_to_testflight — commented out, must not count
              end
            end
            """)
        let actions = findings.map(\.action)
        #expect(actions.contains(.deliver))
        #expect(actions.contains(.pilot))
        #expect(actions.contains(.gym))
        #expect(actions.contains(.appStoreConnectAPIKey))
        #expect(actions.contains(.match))
        #expect(!actions.contains(.uploadToTestflight))
        #expect(actions.filter { $0 == .deliver }.count == 1)
    }

    @Test func fastfileScanUsesWordBoundaries() {
        let findings = FastlaneParsers.scanFastfile("rematch_all\ngym_shortcut\nupload_to_app_store")
        #expect(findings.map(\.action) == [.uploadToAppStore])
    }

    // MARK: Mapping

    @Test func identityKeysLandInUnmappedWithTheAPIKeyReason() {
        let appfile = FastlaneParsers.parse(
            """
            app_identifier "com.example.app"
            apple_id "dev@example.com"
            team_id "ABCDE12345"
            itc_team_id "123456789"
            """,
            fileName: "Appfile", keys: FastlaneParsers.appfileKeys)
        let (values, report) = MigrateCommand.buildMigration(
            appfile: appfile, deliverfile: nil, fastfile: [], metadataDir: nil, screenshotsDir: nil)
        #expect(values["app.bundle_id"] == "com.example.app")
        let unmappedItems = report.unmapped.map(\.item).sorted()
        #expect(unmappedItems == ["apple_id", "itc_team_id", "team_id"])
        #expect(report.unmapped.allSatisfy { $0.reason.contains("App Store Connect API key") })
    }

    @Test func detectedAssetFoldersBecomeConfigPaths() {
        let (values, report) = MigrateCommand.buildMigration(
            appfile: nil, deliverfile: nil, fastfile: [],
            metadataDir: "fastlane/metadata", screenshotsDir: "fastlane/screenshots")
        #expect(values["paths.metadata"] == "fastlane/metadata")
        #expect(values["paths.screenshots"] == "fastlane/screenshots")
        #expect(report.migrated.contains { $0.key == "paths.metadata" && $0.source.contains("reused in place") })
    }

    @Test func gymAndMatchStayUnmappedButNameTheAlternative() {
        let findings = FastlaneParsers.scanFastfile("gym\nmatch\ndeliver\npilot")
        let (_, report) = MigrateCommand.buildMigration(
            appfile: nil, deliverfile: nil, fastfile: findings, metadataDir: nil, screenshotsDir: nil)
        let gym = report.unmapped.first { $0.item == "gym" }
        #expect(gym?.reason.contains("xcodebuild") == true)
        #expect(gym?.reason.contains("appctl builds upload") == true)
        let match = report.unmapped.first { $0.item == "match" }
        #expect(match?.reason.contains("appctl signing repair") == true)
        #expect(match?.reason.contains("ROADMAP") == true)
        let commands = report.suggested.map(\.command)
        #expect(commands.contains { $0.contains("appctl metadata push") })
        #expect(commands.contains("appctl workflow publish"))
    }

    @Test func renderedReportHasAllThreeSections() {
        let (_, report) = MigrateCommand.buildMigration(
            appfile: FastlaneParsers.parse(
                "app_identifier \"com.x.y\"", fileName: "Appfile", keys: FastlaneParsers.appfileKeys),
            deliverfile: nil, fastfile: FastlaneParsers.scanFastfile("deliver\nmatch"),
            metadataDir: nil, screenshotsDir: nil)
        let text = MigrateCommand.renderReport(report)
        #expect(text.contains("Migrated → .appctl.toml"))
        #expect(text.contains("Suggested commands"))
        #expect(text.contains("Unmapped"))
        #expect(text.contains("app.bundle_id = \"com.x.y\""))
    }

    // MARK: Fixture: simple project

    @Test func simpleFixtureProducesConfigAndReport() throws {
        let root = try makeTempProject(
            [
                "fastlane/Appfile": """
                app_identifier "com.example.simple"
                apple_id "dev@example.com"
                team_id "ABCDE12345"
                """,
                "fastlane/Deliverfile": """
                submit_for_review false
                """,
                "fastlane/Fastfile": """
                lane :release do
                  gym(scheme: "Simple")
                  deliver(force: true)
                end
                """,
            ],
            directories: ["fastlane/metadata/en-US", "fastlane/screenshots/en-US"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try MigrateCommand.execute(
            root: root.path, merge: false, force: false, dryRun: false, output: quiet)

        let written = try String(
            contentsOfFile: root.appendingPathComponent(".appctl.toml").path, encoding: .utf8)
        let parsed = ConfigLoader.parseTOML(written)
        #expect(parsed["app.bundle_id"] == "com.example.simple")
        #expect(parsed["paths.metadata"] == "fastlane/metadata")
        #expect(parsed["paths.screenshots"] == "fastlane/screenshots")
        #expect(outcome.wrote)
        #expect(outcome.report.warnings.isEmpty)
        #expect(outcome.report.suggested.contains { $0.command.contains("appctl metadata push") })
        #expect(outcome.report.unmapped.contains { $0.item == "gym" })
        #expect(outcome.report.unmapped.contains { $0.item == "apple_id" })
    }

    // MARK: Fixture: ENV-using project

    @Test func envFixtureWarnsAndOmitsUnresolvableValues() throws {
        let root = try makeTempProject(
            [
                "fastlane/Appfile": """
                app_identifier ENV["BUNDLE_ID"]
                team_id "ABCDE12345"
                """
            ],
            directories: ["fastlane/metadata"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try MigrateCommand.execute(
            root: root.path, merge: false, force: false, dryRun: false, output: quiet)

        let parsed = ConfigLoader.parseTOML(
            try String(
                contentsOfFile: root.appendingPathComponent(".appctl.toml").path, encoding: .utf8))
        #expect(parsed["app.bundle_id"] == nil)
        #expect(parsed["paths.metadata"] == "fastlane/metadata")
        #expect(outcome.report.warnings.count == 1)
        #expect(outcome.report.warnings[0].contains("ENV"))
        #expect(outcome.report.unmapped.contains { $0.item == "team_id" })
    }

    // MARK: Fixture: match-using project

    @Test func matchFixturePointsAtTheRoadmap() throws {
        let root = try makeTempProject([
            "fastlane/Appfile": "app_identifier \"com.example.matched\"",
            "fastlane/Fastfile": """
            lane :beta do
              match(type: "appstore")
              pilot
            end
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try MigrateCommand.execute(
            root: root.path, merge: false, force: false, dryRun: false, output: quiet)

        let match = outcome.report.unmapped.first { $0.item == "match" }
        #expect(match != nil)
        #expect(match?.reason.contains("appctl signing repair") == true)
        #expect(match?.reason.contains("ROADMAP") == true)
        #expect(outcome.report.suggested.contains { $0.command == "appctl workflow publish" })
    }

    // MARK: Overwrite protection, merge, dry-run

    @Test func existingConfigIsNeverSilentlyOverwritten() throws {
        let root = try makeTempProject([
            "fastlane/Appfile": "app_identifier \"com.example.app\"",
            ".appctl.toml": "[auth]\nkey_id = \"KEEP\"\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AppctlError.self) {
            try MigrateCommand.execute(
                root: root.path, merge: false, force: false, dryRun: false, output: quiet)
        }
        let untouched = try String(
            contentsOfFile: root.appendingPathComponent(".appctl.toml").path, encoding: .utf8)
        #expect(untouched.contains("KEEP"))
    }

    @Test func mergeKeepsKeysThisRunDoesNotSet() throws {
        let root = try makeTempProject([
            "fastlane/Appfile": "app_identifier \"com.example.app\"",
            ".appctl.toml": "[auth]\nkey_id = \"KEEP\"\n\n[output]\nformat = \"json\"\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try MigrateCommand.execute(
            root: root.path, merge: true, force: false, dryRun: false, output: quiet)

        let parsed = ConfigLoader.parseTOML(
            try String(
                contentsOfFile: root.appendingPathComponent(".appctl.toml").path, encoding: .utf8))
        #expect(parsed["auth.key_id"] == "KEEP")
        #expect(parsed["output.format"] == "json")
        #expect(parsed["app.bundle_id"] == "com.example.app")
        let backup = root.appendingPathComponent(".appctl.toml.bak").path
        #expect(FileManager.default.fileExists(atPath: backup))
    }

    @Test func dryRunWritesNothing() throws {
        let root = try makeTempProject([
            "fastlane/Appfile": "app_identifier \"com.example.app\""
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try MigrateCommand.execute(
            root: root.path, merge: false, force: false, dryRun: true, output: quiet)

        #expect(!outcome.wrote)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent(".appctl.toml").path))
    }

    @Test func directoryWithoutFastlaneSetupThrows() throws {
        let root = try makeTempProject([:])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AppctlError.self) {
            try MigrateCommand.execute(
                root: root.path, merge: false, force: false, dryRun: false, output: quiet)
        }
    }

    // MARK: Config plumbing for the migrated paths

    @Test func migratedPathKeysRoundTripThroughConfigLoader() {
        let parsed = ConfigLoader.parseTOML(
            ConfigWriter.renderTOML([
                "paths.metadata": "fastlane/metadata",
                "paths.screenshots": "fastlane/screenshots",
            ]))
        #expect(parsed["paths.metadata"] == "fastlane/metadata")
        #expect(parsed["paths.screenshots"] == "fastlane/screenshots")
    }
}
