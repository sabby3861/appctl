import ArgumentParser
import Foundation

/// One-command project setup: discovers App Store Connect credentials (flags,
/// environment, fastlane leftovers, an existing config), validates them against
/// the live API, and writes `.appctl.toml`.
public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create or update .appctl.toml, validating credentials against the live API.")

    @Flag(name: .long, help: "Show example config without writing.") var example = false
    @Flag(name: .long, help: "Overwrite an existing .appctl.toml (backed up to .appctl.toml.bak first).")
    var force = false
    @Flag(name: .long, help: "Merge into an existing .appctl.toml, keeping keys this run does not set.")
    var merge = false
    @Flag(name: .long, help: "Store credentials in the login keychain instead of referencing the key file.")
    var keychain = false
    @Flag(name: .long, help: "Never prompt; fail if a required value is missing. Implied outside a terminal or in CI.")
    var nonInteractive = false
    @Flag(name: .long, help: "Show what would be written without changing anything.")
    var dryRun = false
    @OptionGroup var globals: GlobalOptions
    public init() {}

    public func validate() throws {
        if merge && force {
            throw ValidationError("--merge and --force are mutually exclusive.")
        }
    }

    public func run() async throws {
        if example {
            print(ConfigLoader.exampleConfig())
            return
        }
        let output = try globals.outputFormatter()
        let interactive = !nonInteractive && isatty(STDIN_FILENO) == 1 && !ConfigLoader.isCI()
        let configPath = ".appctl.toml"
        let exists = FileManager.default.fileExists(atPath: configPath)

        var mergeMode = merge
        if exists && !merge && !force {
            guard interactive else {
                throw AppctlError.invalidInput(
                    field: configPath, value: "already exists",
                    expected: "--merge to keep keys this run does not set, or --force to overwrite "
                        + "(either way the previous file is backed up to \(configPath).bak)")
            }
            switch ConfigWriter.promptExistingChoice(configPath: configPath) {
            case .abort: throw AppctlError.operationCancelled
            case .merge: mergeMode = true
            case .overwrite: mergeMode = false
            }
        }

        let existing: [String: String]
        if exists && mergeMode {
            existing = ConfigLoader.parseTOML(try String(contentsOfFile: configPath, encoding: .utf8))
        } else {
            existing = [:]
        }

        let appfile = ["Appfile", "fastlane/Appfile"]
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .first
        let discovered = Self.discover(
            keyIDFlag: globals.keyId, issuerIDFlag: globals.issuerId,
            privateKeyPathFlag: globals.privateKeyPath,
            environment: ProcessInfo.processInfo.environment,
            existing: existing, appfile: appfile)

        let keyID = try Self.require(
            discovered.keyID, label: "API Key ID", flag: "--key-id",
            envVar: "APPCTL_KEY_ID", interactive: interactive, output: output)
        let issuerID = try Self.require(
            discovered.issuerID, label: "Issuer ID", flag: "--issuer-id",
            envVar: "APPCTL_ISSUER_ID", interactive: interactive, output: output)
        let keyPath = try Self.require(
            discovered.privateKeyPath, label: "Path to .p8 key file", flag: "--private-key-path",
            envVar: "APPCTL_PRIVATE_KEY_PATH", interactive: interactive, output: output)
        if let bundle = discovered.bundleID {
            output.info("Bundle ID: \(bundle.value) (from \(bundle.source))")
        }

        let resolvedKeyPath = (keyPath as NSString).expandingTildeInPath
        switch AuthStore.validateKeyFile(at: resolvedKeyPath) {
        case .success: output.success("Private key is valid")
        case .failure(let error): throw error
        }

        var useKeychain = keychain
        if !useKeychain && interactive {
            useKeychain = promptYesNo(
                "Store credentials in your login keychain instead of referencing the key file?")
        }

        let candidate = AppctlConfig(
            keyID: keyID, issuerID: issuerID, privateKeyPath: resolvedKeyPath,
            verbose: globals.verbose, timeout: globals.timeout ?? 30)
        let client = try globals.apiClient(candidate: candidate)
        try await Self.execute(
            client: client, output: output, keyID: keyID, issuerID: issuerID,
            keyPath: keyPath, resolvedKeyPath: resolvedKeyPath, existing: existing,
            bundleID: discovered.bundleID?.value, useKeychain: useKeychain,
            configPath: configPath, exists: exists, dryRun: dryRun,
            nextActions: globals.nextActions())
    }

    static func execute(
        client: any AppStoreConnectClient, output: OutputFormatter, keyID: String,
        issuerID: String, keyPath: String, resolvedKeyPath: String,
        existing: [String: String], bundleID: String?, useKeychain: Bool,
        configPath: String, exists: Bool, dryRun: Bool, nextActions: NextActions
    ) async throws {
        try await validateLive(client: client, output: output, next: nextCommands(nextActions))

        let values = fileValues(
            existing: existing, keyID: keyID, issuerID: issuerID, keyPath: keyPath,
            bundleID: bundleID, useKeychain: useKeychain)
        let rendered = ConfigWriter.renderTOML(values)
        let store = KeychainCredentialStore()

        if dryRun {
            var err = StandardError.shared
            printDryRun(
                rendered: rendered, configPath: configPath, exists: exists,
                useKeychain: useKeychain, keychainService: store.service,
                output: output, stream: &err)
            printNextSteps(output: output, nextActions: nextActions)
            return
        }

        if useKeychain {
            let pem = try String(contentsOfFile: resolvedKeyPath, encoding: .utf8)
            try store.store(keyID, account: .keyID)
            try store.store(issuerID, account: .issuerID)
            try store.store(pem, account: .privateKey)
            output.success("Credentials stored in your login keychain (service \"\(store.service)\").")
        }
        let backup = try ConfigWriter.writeConfig(rendered, to: configPath, output: output)
        if let backup {
            output.info(
                "Previous config backed up to \(backup) (comments are not carried into the rewritten file).")
        }
        output.success("\(exists ? "Updated" : "Created") \(configPath)")
        printNextSteps(output: output, nextActions: nextActions)
    }

    // MARK: - Credential discovery

    struct SourcedValue: Sendable, Equatable {
        let value: String
        let source: String
    }

    struct DiscoveredCredentials: Sendable, Equatable {
        var keyID: SourcedValue?
        var issuerID: SourcedValue?
        var privateKeyPath: SourcedValue?
        var bundleID: SourcedValue?
    }

    /// Resolution order per value: explicit flag, appctl environment, fastlane's
    /// APP_STORE_CONNECT_API_KEY_* environment, then (in merge mode) the existing
    /// config file. The bundle ID additionally falls back to a fastlane Appfile —
    /// the only thing an Appfile can contribute, since credentials never live there.
    static func discover(
        keyIDFlag: String?, issuerIDFlag: String?, privateKeyPathFlag: String?,
        environment: [String: String], existing: [String: String], appfile: String?
    ) -> DiscoveredCredentials {
        DiscoveredCredentials(
            keyID: pick([
                (keyIDFlag, "--key-id"),
                (environment["APPCTL_KEY_ID"], "APPCTL_KEY_ID"),
                (environment["APP_STORE_CONNECT_API_KEY_KEY_ID"], "APP_STORE_CONNECT_API_KEY_KEY_ID"),
                (existing["auth.key_id"], ".appctl.toml"),
            ]),
            issuerID: pick([
                (issuerIDFlag, "--issuer-id"),
                (environment["APPCTL_ISSUER_ID"], "APPCTL_ISSUER_ID"),
                (environment["APP_STORE_CONNECT_API_KEY_ISSUER_ID"], "APP_STORE_CONNECT_API_KEY_ISSUER_ID"),
                (existing["auth.issuer_id"], ".appctl.toml"),
            ]),
            privateKeyPath: pick([
                (privateKeyPathFlag, "--private-key-path"),
                (environment["APPCTL_PRIVATE_KEY_PATH"], "APPCTL_PRIVATE_KEY_PATH"),
                (
                    environment["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"],
                    "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"
                ),
                (existing["auth.private_key_path"], ".appctl.toml"),
            ]),
            bundleID: pick([
                (existing["app.bundle_id"], ".appctl.toml"),
                (appfile.flatMap(parseAppfile), "fastlane Appfile"),
            ]))
    }

    private static func pick(_ candidates: [(String?, String)]) -> SourcedValue? {
        for (value, source) in candidates {
            if let value, !value.isEmpty { return SourcedValue(value: value, source: source) }
        }
        return nil
    }

    /// Extracts `app_identifier` from a fastlane Appfile. Deliberately tiny Ruby
    /// subset (mirroring `ConfigLoader.parseTOML`'s approach): a literal quoted
    /// string, with or without parentheses. `ENV[...]`-backed values are skipped —
    /// their expansion belongs to fastlane, not us.
    static func parseAppfile(_ content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("app_identifier") else { continue }
            if let match = trimmed.firstMatch(of: #/app_identifier\s*\(?\s*["']([^"']+)["']/#) {
                return String(match.1)
            }
        }
        return nil
    }

    // MARK: - Live validation

    /// The live credential check: one `GET /v1/apps?limit=1`. Prints the returned
    /// app plus the account total so success is visibly more than a status code.
    /// `next` rides the JSON envelope, where stderr chatter is suppressed and the
    /// suggested commands would otherwise be lost.
    static func validateLive(
        client: any AppStoreConnectClient, output: OutputFormatter, next: [String: String]? = nil
    ) async throws {
        let spinner = output.startSpinner("Validating credentials against App Store Connect")
        do {
            let response: APIListResponse<App> = try await client.getList(
                "apps",
                queryItems: [URLQueryItem(name: "fields[apps]", value: "name,bundleId")],
                limit: 1, pageSize: 1)
            spinner.stop()
            let total = response.meta?.paging?.total ?? response.data.count
            output.success("Credentials valid — account has \(total) app\(total == 1 ? "" : "s").")
            output.printList(
                response.data,
                columns: [
                    Column(header: "ID") { $0.id },
                    Column(header: "Name") { $0.attributes?.name ?? "—" },
                    Column(header: "Bundle ID") { $0.attributes?.bundleId ?? "—" },
                ], emptyMessage: "No apps in this account yet — credentials work.", next: next)
        } catch {
            spinner.stop(success: false)
            throw Self.refineForbidden(error)
        }
    }

    /// Documented ASC trap: pending developer agreements make every endpoint
    /// return 403 FORBIDDEN — usually without mentioning the agreement — even
    /// though the token is valid (an invalid token yields 401). At this point the
    /// JWT was accepted, so a 403 means the account is blocked, not the key.
    static func refineForbidden(_ error: Error) -> Error {
        let status: Int?
        switch error {
        case AppctlError.apiError(_, let code, _): status = code
        case AppctlError.requestFailed(_, let code, _): status = code
        default: status = nil
        }
        guard status == 403 else { return error }
        return AppctlError.agreementPending(
            detail: "GET /v1/apps returned HTTP 403 even though the token was accepted. "
                + "When every endpoint responds 403 with valid credentials, the account is blocked, not the key.")
    }

    // MARK: - Config assembly

    /// The flat key map the config file should end up with: `existing` carries
    /// merge-mode keys this run does not manage. In keychain mode the auth keys
    /// are dropped from the file — keychain entries win at load time, and one
    /// source of truth beats two that can drift.
    static func fileValues(
        existing: [String: String], keyID: String, issuerID: String, keyPath: String,
        bundleID: String?, useKeychain: Bool
    ) -> [String: String] {
        var values = existing
        if useKeychain {
            values["auth.key_id"] = nil
            values["auth.issuer_id"] = nil
            values["auth.private_key_path"] = nil
        } else {
            values["auth.key_id"] = keyID
            values["auth.issuer_id"] = issuerID
            values["auth.private_key_path"] = keyPath
        }
        if let bundleID { values["app.bundle_id"] = bundleID }
        return values
    }

    /// Dry-run preview. Everything — including the rendered TOML — goes to the
    /// stderr stream, never stdout: in JSON mode stdout already carries the
    /// validation envelope and must remain a single valid JSON document.
    static func printDryRun(
        rendered: String, configPath: String, exists: Bool, useKeychain: Bool,
        keychainService: String, output: OutputFormatter, stream: inout some TextOutputStream
    ) {
        if exists { output.info("Dry run: would back up \(configPath) to \(configPath).bak.") }
        output.info("Dry run: would write \(configPath):")
        print(rendered, terminator: "", to: &stream)
        if useKeychain {
            output.info(
                "Dry run: would store credentials in your login keychain (service \"\(keychainService)\").")
        }
    }

    // MARK: - Prompting

    static func require(
        _ discovered: SourcedValue?, label: String, flag: String, envVar: String,
        interactive: Bool, output: OutputFormatter
    ) throws -> String {
        if let discovered {
            output.info("\(label): \(discovered.value) (from \(discovered.source))")
            return discovered.value
        }
        guard interactive else {
            throw AppctlError.invalidInput(
                field: label, value: "(missing)",
                expected: "Pass \(flag) or set \(envVar) when running non-interactively")
        }
        return try promptRequired(label)
    }

    private static func promptRequired(_ label: String, attempts: Int = 0) throws -> String {
        if attempts >= 3 {
            throw AppctlError.invalidInput(
                field: label, value: "(empty after \(attempts) attempts)", expected: "A non-empty value")
        }
        // Prompts go to stderr so a user piping stdout still sees what's being asked.
        var err = StandardError.shared
        print("  \(label): ", terminator: "", to: &err)
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
            print("  \(label) is required.", to: &err)
            return try promptRequired(label, attempts: attempts + 1)
        }
        return input
    }

    private func promptYesNo(_ question: String) -> Bool {
        var err = StandardError.shared
        print("  \(question) [y/N]: ", terminator: "", to: &err)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    private static func nextCommands(_ next: NextActions) -> [String: String] {
        [
            "listApps": next.command(["apps", "list"]),
            "doctor": next.command(["doctor"]),
            "release": next.command(["workflow", "release"]),
        ]
    }

    private static func printNextSteps(output: OutputFormatter, nextActions next: NextActions) {
        output.info("Next steps:")
        output.info("  \(next.command(["apps", "list"])) — list your apps")
        output.info("  \(next.command(["doctor"])) — check your environment")
        output.info("  \(next.command(["workflow", "release"])) — run the release pipeline")
    }
}
