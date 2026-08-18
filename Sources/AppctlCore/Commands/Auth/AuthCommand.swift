import ArgumentParser
import Foundation

public struct AuthCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auth", abstract: "Manage App Store Connect API authentication.",
        subcommands: [Setup.self, Verify.self, Status.self], defaultSubcommand: Status.self)
    public init() {}

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Configure API key credentials.")
        @Option(name: .long, help: "API Key ID.") var keyId: String?
        @Option(name: .long, help: "Issuer ID.") var issuerId: String?
        @Option(name: .long, help: "Path to .p8 key file.") var privateKeyPath: String?
        @Flag(name: .long, help: "Write to global config.") var global = false
        @Flag(name: .long, help: "Store credentials in the login keychain instead of a config file.")
        var keychain = false
        @Flag(name: .long, help: "Remove appctl credentials from the login keychain and exit.")
        var removeKeychain = false
        @Flag(name: .long, help: "Show what would be stored or removed without changing anything.")
        var dryRun = false
        init() {}

        func validate() throws {
            if keychain && removeKeychain {
                throw ValidationError("--keychain and --remove-keychain are mutually exclusive.")
            }
            if keychain && global {
                throw ValidationError("--global has no effect with --keychain; credentials go to the login keychain.")
            }
        }

        func run() async throws {
            let output = OutputFormatter()
            if removeKeychain {
                try Self.removeKeychainCredentials(output: output, dryRun: dryRun)
                return
            }
            let keyID = try keyId ?? promptRequired("API Key ID")
            let issuerID = try issuerId ?? promptRequired("Issuer ID")
            let keyPath = try privateKeyPath ?? promptRequired("Path to .p8 key file")
            try Self.execute(
                output: output, keyID: keyID, issuerID: issuerID, keyPath: keyPath,
                global: global, keychain: keychain, dryRun: dryRun)
        }

        static func execute(
            output: OutputFormatter, keyID: String, issuerID: String, keyPath: String,
            global: Bool, keychain: Bool, dryRun: Bool
        ) throws {
            let resolved = (keyPath as NSString).expandingTildeInPath
            output.info("Validating private key...")
            switch AuthStore.validateKeyFile(at: resolved) {
            case .success: output.success("Private key is valid")
            case .failure(let error):
                output.error(error.diagnosticMessage)
                throw error
            }
            if keychain {
                try storeInKeychain(
                    keyID: keyID, issuerID: issuerID, resolvedKeyPath: resolved,
                    output: output, dryRun: dryRun)
                return
            }
            let configPath: String
            if global {
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/appctl")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                configPath = dir.appendingPathComponent("config.toml").path
            } else {
                configPath = ".appctl.toml"
            }
            let config = ConfigLoader.exampleConfig()
                .replacingOccurrences(of: "# key_id = \"XXXXXXXXXX\"", with: "key_id = \"\(keyID)\"")
                .replacingOccurrences(
                    of: "# issuer_id = \"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\"", with: "issuer_id = \"\(issuerID)\""
                )
                .replacingOccurrences(
                    of: "# private_key_path = \"~/.config/appctl/AuthKey.p8\"",
                    with: "private_key_path = \"\(keyPath)\"")
            if dryRun {
                output.info(
                    "Dry run: would write configuration to \(configPath) referencing \(keyPath). Nothing written.")
                return
            }
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)
            // Restrict to owner read/write — the file references the path to a private key.
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: configPath
                )
            } catch {
                output.warning(
                    "Saved \(configPath) but could not set 0600 permissions (\(error.localizedDescription)). "
                        + "Consider running: chmod 600 \(configPath)"
                )
            }
            output.success("Configuration saved to \(configPath)")
        }

        private static func storeInKeychain(
            keyID: String, issuerID: String, resolvedKeyPath: String, output: OutputFormatter,
            dryRun: Bool
        ) throws {
            let pem = try String(contentsOfFile: resolvedKeyPath, encoding: .utf8)
            let store = KeychainCredentialStore()
            let accounts = KeychainCredentialStore.Account.allCases.map(\.rawValue).joined(separator: ", ")
            if dryRun {
                output.info(
                    "Dry run: would store credentials in your login keychain — service \"\(store.service)\", "
                        + "accounts \(accounts). Nothing written.")
                return
            }
            try store.store(keyID, account: .keyID)
            try store.store(issuerID, account: .issuerID)
            try store.store(pem, account: .privateKey)
            output.success("Credentials stored in your login keychain.")
            output.printDetail(fields: [
                ("Service:", store.service),
                ("Accounts:", accounts),
            ])
            output.info(
                "Find them in Keychain Access by searching \"\(store.service)\". "
                    + "Remove them with `appctl auth setup --remove-keychain`.")
        }

        private static func removeKeychainCredentials(output: OutputFormatter, dryRun: Bool) throws {
            let store = KeychainCredentialStore()
            let accounts = KeychainCredentialStore.Account.allCases
            if dryRun {
                output.info(
                    "Dry run: would remove keychain items — service \"\(store.service)\", "
                        + "accounts \(accounts.map(\.rawValue).joined(separator: ", ")). Nothing removed.")
                return
            }
            var removed: [String] = []
            for account in accounts {
                if try store.delete(account) { removed.append(account.rawValue) }
            }
            if removed.isEmpty {
                output.info("No appctl credentials found in the keychain (service \"\(store.service)\").")
            } else {
                output.success(
                    "Removed keychain item\(removed.count == 1 ? "" : "s") \(removed.joined(separator: ", ")) "
                        + "(service \"\(store.service)\").")
            }
        }

        private func promptRequired(_ label: String, attempts: Int = 0) throws -> String {
            if isatty(STDIN_FILENO) == 0 {
                throw AppctlError.invalidInput(
                    field: label,
                    value: "(missing)",
                    expected: "A value — pass --key-id / --issuer-id / --private-key-path in non-interactive mode"
                )
            }
            if attempts >= 3 {
                throw AppctlError.invalidInput(
                    field: label,
                    value: "(empty after \(attempts) attempts)",
                    expected: "A non-empty value"
                )
            }
            // Prompt on stderr so a user piping stdout still sees what's being asked.
            var err = StandardError.shared
            print("  \(label): ", terminator: "", to: &err)
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
                print("  \(label) is required.", to: &err)
                return try promptRequired(label, attempts: attempts + 1)
            }
            return input
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Verify your API credentials.")
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter
        ) async throws {
            let spinner = output.startSpinner("Verifying credentials")
            do {
                let r: APIListResponse<App> = try await client.getList("apps", limit: 1, pageSize: 1)
                spinner.stop()
                let total = r.meta?.paging?.total ?? r.data.count
                output.success("Authentication successful. Account has \(total) app\(total == 1 ? "" : "s").")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current authentication status.")
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let output = try globals.outputFormatter()
            let config = try globals.resolvedConfig()
            Self.execute(output: output, config: config)
        }

        static func execute(output: OutputFormatter, config: AppctlConfig) {
            let masked = config.issuerID.map { id in id.count > 8 ? "\(id.prefix(4))…\(id.suffix(4))" : id }
            let store = KeychainCredentialStore()
            let source: String
            if ProcessInfo.processInfo.environment["APPCTL_KEY_ID"] != nil {
                source = "Environment variables"
            } else if (try? store.read(.keyID)).flatMap({ $0 }) != nil {
                source = "Keychain (\(store.service))"
            } else if FileManager.default.fileExists(atPath: ".appctl.toml") {
                source = ".appctl.toml (project)"
            } else {
                source = "None found"
            }
            let keyFile =
                config.privateKeyPath ?? (config.privateKeyPEM != nil ? "(login keychain)" : "Not configured")
            output.printDetail(fields: [
                ("Key ID:", config.keyID ?? "Not configured"),
                ("Issuer ID:", masked ?? "Not configured"), ("Key File:", keyFile),
                ("Config Source:", source), ("CI Environment:", ConfigLoader.isCI() ? "Yes" : "No"),
            ])
        }
    }
}

/// Shared global flags composed into command groups via `@OptionGroup`. Internal
/// because no SemVer commitment is intended outside the AppctlCore module.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "API Key ID.") var keyId: String?
    @Option(name: .long, help: "Issuer ID.") var issuerId: String?
    @Option(name: .long, help: "Path to .p8 key file.") var privateKeyPath: String?
    @Option(name: .long, help: "Output format: text, json, table, markdown, csv.")
    var output: String?
    /// Deprecated spelling of --output, kept hidden for compatibility.
    @Option(name: .long, help: .hidden) var format: String?
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Filter JSON output: dot paths, [N], [*], [?field=='x']. Implies --output json.",
            valueName: "expr"))
    var query: String?
    @Flag(name: .long, help: "Suppress progress and success chatter on stderr.")
    var quiet = false
    @Flag(
        name: .long,
        help: "Assume \"yes\" for confirmation prompts. Typed-confirmation commands refuse it.")
    var yes = false
    @Option(name: .long, help: "Network timeout in seconds.") var timeout: Double?
    @Flag(name: .long, help: "Show verbose output.") var verbose = false
    @Flag(name: .long, help: "Disable colored output.") var noColor = false
    /// Hidden rehearsal mode: serves offline fixtures instead of touching credentials
    /// or the network. Placed per-subcommand (`appctl workflow release … --mock`)
    /// because ArgumentParser does not propagate root-level flags to subcommands.
    @Flag(name: .long, help: .hidden) var mock = false
    init() {}

    private var formatArgument: String? { output ?? format }

    func resolvedOutputFormat() throws -> OutputFormat {
        guard let f = formatArgument else {
            if query != nil { return .json }
            return (!ConfigLoader.isTerminal() || ConfigLoader.isCI()) ? .json : .text
        }
        guard let parsed = OutputFormat(rawValue: f) else {
            throw AppctlError.invalidInput(
                field: "--output", value: f,
                expected: OutputFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if query != nil, parsed != .json {
            throw AppctlError.invalidInput(
                field: "--query", value: "with --output \(f)",
                expected: "--query filters JSON output; drop --output or use --output json")
        }
        return parsed
    }

    func outputFormatter() throws -> OutputFormatter {
        OutputFormatter(
            format: try resolvedOutputFormat(), noColor: noColor, quiet: quiet,
            query: try query.map(QueryEvaluator.init(parsing:)))
    }

    /// Explicitly-passed flags that suggested `next` commands must carry so they run
    /// against the same account in the same output mode. When a profile/--team
    /// concept lands (G6), extend this list — `NextActions` call sites take it verbatim.
    var propagatedFlags: [String] {
        var flags: [String] = []
        if let keyId { flags += ["--key-id", keyId] }
        if let issuerId { flags += ["--issuer-id", issuerId] }
        if let privateKeyPath { flags += ["--private-key-path", privateKeyPath] }
        if let f = formatArgument { flags += ["--output", f] }
        if mock { flags.append("--mock") }
        return flags
    }

    func nextActions() -> NextActions { NextActions(propagatedFlags: propagatedFlags) }

    func resolvedConfig() throws -> AppctlConfig {
        try ConfigLoader.load(
            keyIDOverride: keyId, issuerIDOverride: issuerId,
            privateKeyPathOverride: privateKeyPath, formatOverride: formatArgument,
            verboseOverride: verbose, noColorOverride: noColor)
    }

    /// The only place a concrete client is constructed. The `timeout` parameter
    /// overrides both the --timeout flag and the configured value, for callers
    /// that need a snappier check (doctor).
    func apiClient(timeout: TimeInterval? = nil) throws -> (any AppStoreConnectClient, AppctlConfig) {
        if mock {
            return (FixtureClient(), FixtureClient.mockConfig(verbose: verbose, noColor: noColor))
        }
        let config = try resolvedConfig()
        let gen = try AuthStore.createGenerator(from: config)
        let effectiveTimeout = timeout ?? self.timeout ?? config.timeout
        return (
            APIClient(jwtGenerator: gen, verbose: config.verbose, timeout: effectiveTimeout), config
        )
    }

    /// Builds a client from candidate credentials that are not persisted anywhere
    /// yet (`init` validates before writing config), keeping concrete client
    /// construction inside the composition root.
    func apiClient(candidate config: AppctlConfig) throws -> any AppStoreConnectClient {
        if mock { return FixtureClient() }
        let gen = try AuthStore.createGenerator(from: config)
        return APIClient(
            jwtGenerator: gen, verbose: config.verbose, timeout: timeout ?? config.timeout)
    }
}
