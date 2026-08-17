import ArgumentParser
import Foundation

/// Converts a fastlane setup into appctl configuration without executing any
/// Ruby: literal values move into `.appctl.toml`, detected `metadata/` and
/// `screenshots/` folders are reused in place (appctl reads the fastlane
/// layout), and everything dynamic lands in a three-section report — Migrated,
/// Suggested commands, Unmapped — so nothing disappears silently. Unmapped
/// items are expected, not failures: the command still exits 0.
public struct MigrateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Migrate a fastlane project to appctl.",
        discussion: """
            Reads Appfile, Deliverfile and Fastfile (never executing Ruby), writes
            .appctl.toml, and prints a report of what migrated, which appctl commands
            replace your lanes, and what has no equivalent yet.
            """)

    @Flag(
        name: .customLong("from-fastlane"),
        help: "Migrate from a fastlane setup (Appfile, Deliverfile, Fastfile).")
    var fromFastlane = false
    @Argument(help: "Project directory containing the fastlane setup.")
    var path: String = "."
    @Flag(name: .long, help: "Merge into an existing .appctl.toml, keeping keys this run does not set.")
    var merge = false
    @Flag(name: .long, help: "Overwrite an existing .appctl.toml (backed up to .appctl.toml.bak first).")
    var force = false
    @Flag(name: .long, help: "Show what would be written without changing anything.")
    var dryRun = false
    @Flag(
        name: .long,
        help: "Never prompt; fail if .appctl.toml exists without --merge/--force. Implied outside a terminal or in CI.")
    var nonInteractive = false
    @OptionGroup var globals: GlobalOptions
    public init() {}

    public func validate() throws {
        if !fromFastlane {
            throw ValidationError("Pass --from-fastlane; it is currently the only supported migration source.")
        }
        if merge && force {
            throw ValidationError("--merge and --force are mutually exclusive.")
        }
    }

    public func run() async throws {
        let output = try globals.outputFormatter()
        let interactive = !nonInteractive && isatty(STDIN_FILENO) == 1 && !ConfigLoader.isCI()
        let configPath = Self.configPath(root: path)

        var mergeMode = merge
        var forceMode = force
        if FileManager.default.fileExists(atPath: configPath) && !merge && !force && !dryRun && interactive {
            switch ConfigWriter.promptExistingChoice(configPath: configPath) {
            case .abort: throw AppctlError.operationCancelled
            case .merge: mergeMode = true
            case .overwrite: forceMode = true
            }
        }

        let next = globals.nextActions()
        _ = try Self.execute(
            root: path, merge: mergeMode, force: forceMode, dryRun: dryRun, output: output,
            next: [
                "doctor": next.command(["doctor"]),
                "release": next.command(["workflow", "release"]),
            ])
    }

    // MARK: - Report model

    struct MigrationReport: Sendable, Equatable {
        struct Migrated: Sendable, Equatable {
            let key: String
            let value: String
            let source: String
        }
        struct Suggestion: Sendable, Equatable {
            let source: String
            let command: String
            let note: String?
        }
        struct Unmapped: Sendable, Equatable {
            let item: String
            let source: String
            let reason: String
        }
        var migrated: [Migrated] = []
        var suggested: [Suggestion] = []
        var unmapped: [Unmapped] = []
        var warnings: [String] = []
    }

    struct Outcome: Sendable {
        let report: MigrationReport
        let configValues: [String: String]
        let wrote: Bool
        let backupPath: String?
    }

    // MARK: - Execution seam (no API client: migrate is a local file transformation)

    static func configPath(root: String) -> String {
        (root as NSString).appendingPathComponent(".appctl.toml")
    }

    static func execute(
        root: String, merge: Bool, force: Bool, dryRun: Bool,
        output: OutputFormatter, next: [String: String]? = nil
    ) throws -> Outcome {
        let appfile = readFastlaneFile("Appfile", root: root)
        let deliverfile = readFastlaneFile("Deliverfile", root: root)
        let fastfile = readFastlaneFile("Fastfile", root: root)

        let parsedAppfile = appfile.map {
            FastlaneParsers.parse($0.content, fileName: $0.name, keys: FastlaneParsers.appfileKeys)
        }
        let parsedDeliverfile = deliverfile.map {
            FastlaneParsers.parse($0.content, fileName: $0.name)
        }
        let fastfileFindings = fastfile.map { FastlaneParsers.scanFastfile($0.content) } ?? []

        let metadataDir = detectAssetDirectory(
            root: root, configured: parsedDeliverfile?.values["metadata_path"], name: "metadata")
        let screenshotsDir = detectAssetDirectory(
            root: root, configured: parsedDeliverfile?.values["screenshots_path"], name: "screenshots")

        guard
            appfile != nil || deliverfile != nil || fastfile != nil
                || metadataDir != nil || screenshotsDir != nil
        else {
            throw AppctlError.invalidInput(
                field: "path", value: root,
                expected: "a directory containing a fastlane setup "
                    + "(Appfile, Deliverfile, Fastfile, metadata/ or screenshots/ — "
                    + "checked both <path>/ and <path>/fastlane/)")
        }

        var (values, report) = buildMigration(
            appfile: parsedAppfile, deliverfile: parsedDeliverfile,
            fastfile: fastfileFindings, metadataDir: metadataDir, screenshotsDir: screenshotsDir)

        let configPath = configPath(root: root)
        let exists = FileManager.default.fileExists(atPath: configPath)
        if exists && !merge && !force && !dryRun {
            throw AppctlError.invalidInput(
                field: configPath, value: "already exists",
                expected: "--merge to keep keys this run does not set, or --force to overwrite "
                    + "(either way the previous file is backed up to \(configPath).bak)")
        }
        if exists && merge {
            let existing = ConfigLoader.parseTOML(
                try String(contentsOfFile: configPath, encoding: .utf8))
            values = existing.merging(values) { _, migrated in migrated }
        }
        let rendered = ConfigWriter.renderTOML(values)

        var wrote = false
        var backupPath: String?
        if dryRun {
            var err = StandardError.shared
            if exists { output.info("Dry run: would back up \(configPath) to \(configPath).bak.") }
            output.info("Dry run: would write \(configPath):")
            print(rendered, terminator: "", to: &err)
        } else {
            backupPath = try ConfigWriter.writeConfig(rendered, to: configPath, output: output)
            wrote = true
            if let backupPath {
                output.info("Previous config backed up to \(backupPath).")
            }
            output.success("\(exists ? "Updated" : "Created") \(configPath)")
        }

        emit(report: report, configPath: configPath, dryRun: dryRun, output: output, next: next)
        return Outcome(report: report, configValues: values, wrote: wrote, backupPath: backupPath)
    }

    // MARK: - Discovery

    /// fastlane convention puts its files in `fastlane/`, but all of them also
    /// work at the project root; check the conventional home first.
    private static func readFastlaneFile(_ name: String, root: String) -> (name: String, content: String)? {
        for candidate in ["fastlane/\(name)", name] {
            let full = (root as NSString).appendingPathComponent(candidate)
            if let content = try? String(contentsOfFile: full, encoding: .utf8) {
                return (candidate, content)
            }
        }
        return nil
    }

    /// Resolves the asset directory to record in config, relative to `root`
    /// (which is where `.appctl.toml` lands): an explicit Deliverfile path wins,
    /// then the conventional locations. Only existing directories count.
    static func detectAssetDirectory(root: String, configured: String?, name: String) -> String? {
        let candidates = [configured, "fastlane/\(name)", name].compactMap { $0 }
        for candidate in candidates {
            let full =
                candidate.hasPrefix("/")
                ? candidate : (root as NSString).appendingPathComponent(candidate)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Mapping

    /// Deliverfile keys that carry account identity. appctl authenticates with
    /// an App Store Connect API key, so none of them move into config.
    private static let identityKeys: Set<String> = [
        "apple_id", "team_id", "itc_team_id", "team_name", "username",
    ]
    private static let identityReason =
        "not needed — appctl authenticates with an App Store Connect API key (`appctl init` sets one up)"

    static func buildMigration(
        appfile: FastlaneParsers.ParsedFile?, deliverfile: FastlaneParsers.ParsedFile?,
        fastfile: [FastlaneParsers.FastfileFinding], metadataDir: String?, screenshotsDir: String?
    ) -> (values: [String: String], report: MigrationReport) {
        var values: [String: String] = [:]
        var report = MigrationReport()
        report.warnings = (appfile?.warnings ?? []) + (deliverfile?.warnings ?? [])

        if let bundle = appfile?.values["app_identifier"] {
            values["app.bundle_id"] = bundle
            report.migrated.append(.init(key: "app.bundle_id", value: bundle, source: "Appfile app_identifier"))
        } else if let bundle = deliverfile?.values["app_identifier"] {
            values["app.bundle_id"] = bundle
            report.migrated.append(
                .init(key: "app.bundle_id", value: bundle, source: "Deliverfile app_identifier"))
        }

        if let metadataDir {
            values["paths.metadata"] = metadataDir
            report.migrated.append(
                .init(
                    key: "paths.metadata", value: metadataDir,
                    source: "reused in place — appctl reads the fastlane layout, "
                        + "and `appctl metadata push` now finds it without --path"))
        }
        if let screenshotsDir {
            values["paths.screenshots"] = screenshotsDir
            report.migrated.append(
                .init(
                    key: "paths.screenshots", value: screenshotsDir,
                    source: "reused in place — appctl reads the fastlane layout, "
                        + "and `appctl screenshots upload` now finds it without --path"))
        }

        for key in FastlaneParsers.appfileKeys.subtracting(["app_identifier"]).sorted() {
            if appfile?.values[key] != nil {
                report.unmapped.append(.init(item: key, source: "Appfile", reason: identityReason))
            }
        }
        for (key, _) in (deliverfile?.values ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch key {
            case "app_identifier", "metadata_path", "screenshots_path":
                continue  // already handled above
            case _ where identityKeys.contains(key):
                report.unmapped.append(.init(item: key, source: "Deliverfile", reason: identityReason))
            case "submit_for_review":
                report.unmapped.append(
                    .init(
                        item: key, source: "Deliverfile",
                        reason: "submission is an explicit step in appctl — `appctl workflow release` drives it"))
            case "skip_metadata", "skip_screenshots":
                report.unmapped.append(
                    .init(
                        item: key, source: "Deliverfile",
                        reason: "not needed — run only the push commands you want"))
            case "force":
                report.unmapped.append(
                    .init(
                        item: key, source: "Deliverfile",
                        reason: "no equivalent — appctl confirmation prompts are controlled per run with --yes"))
            default:
                report.unmapped.append(
                    .init(
                        item: key, source: "Deliverfile",
                        reason: "no .appctl.toml equivalent — pass per-command flags instead"))
            }
        }

        for finding in fastfile {
            let source = "Fastfile:\(finding.lineNumber)"
            switch finding.action {
            case .deliver, .uploadToAppStore:
                report.suggested.append(
                    .init(
                        source: "\(finding.action.rawValue) (\(source))",
                        command: "appctl metadata push && appctl screenshots upload",
                        note: "or run the full pipeline: appctl workflow release"))
            case .pilot, .uploadToTestflight:
                report.suggested.append(
                    .init(
                        source: "\(finding.action.rawValue) (\(source))",
                        command: "appctl workflow publish",
                        note: "TestFlight distribution, including build upload and group assignment"))
            case .appStoreConnectAPIKey:
                report.suggested.append(
                    .init(
                        source: "app_store_connect_api_key (\(source))",
                        command: "appctl init",
                        note:
                            "validates credentials against the live API and stores them in .appctl.toml or the keychain"
                    ))
            case .gym:
                report.unmapped.append(
                    .init(
                        item: "gym", source: source,
                        reason: "appctl does not build — keep `xcodebuild` (pipe through xcbeautify), "
                            + "then upload the result with `appctl builds upload`"))
            case .match:
                report.unmapped.append(
                    .init(
                        item: "match", source: source,
                        reason: "code signing sync is outside appctl today — profile repair is planned "
                            + "as `appctl signing repair` (see ROADMAP); `appctl certificates list` "
                            + "shows what is installed"))
            }
        }
        return (values, report)
    }

    // MARK: - Report output

    /// Text report goes to stdout — it is the command's primary result, like a
    /// table from a list command. JSON mode routes the same structure through
    /// the versioned envelope, with parse warnings in the envelope's `warnings`.
    private static func emit(
        report: MigrationReport, configPath: String, dryRun: Bool,
        output: OutputFormatter, next: [String: String]?
    ) {
        if output.format == .json {
            output.printEnvelope(
                data: reportJSON(report, configPath: configPath, dryRun: dryRun),
                warnings: report.warnings, next: next)
            return
        }
        for warning in report.warnings { output.warning(warning) }
        print(renderReport(report))
    }

    static func renderReport(_ report: MigrationReport) -> String {
        var lines: [String] = []
        lines.append("Migrated → .appctl.toml")
        if report.migrated.isEmpty {
            lines.append("  (nothing — no literal values found)")
        }
        for entry in report.migrated {
            lines.append("  \(entry.key) = \"\(entry.value)\"")
            lines.append("      \(entry.source)")
        }
        lines.append("")
        lines.append("Suggested commands")
        if report.suggested.isEmpty { lines.append("  (none)") }
        for entry in report.suggested {
            lines.append("  \(entry.source) → \(entry.command)")
            if let note = entry.note { lines.append("      \(note)") }
        }
        lines.append("")
        lines.append("Unmapped")
        if report.unmapped.isEmpty { lines.append("  (none — everything found an appctl home)") }
        for entry in report.unmapped {
            lines.append("  \(entry.item) (\(entry.source)) — \(entry.reason)")
        }
        return lines.joined(separator: "\n")
    }

    static func reportJSON(_ report: MigrationReport, configPath: String, dryRun: Bool) -> JSONValue {
        .object([
            "configPath": .string(configPath),
            "dryRun": .bool(dryRun),
            "migrated": .array(
                report.migrated.map {
                    .object(["key": .string($0.key), "value": .string($0.value), "source": .string($0.source)])
                }),
            "suggested": .array(
                report.suggested.map {
                    .object([
                        "source": .string($0.source), "command": .string($0.command),
                        "note": $0.note.map(JSONValue.string) ?? .null,
                    ])
                }),
            "unmapped": .array(
                report.unmapped.map {
                    .object([
                        "item": .string($0.item), "source": .string($0.source),
                        "reason": .string($0.reason),
                    ])
                }),
        ])
    }
}
