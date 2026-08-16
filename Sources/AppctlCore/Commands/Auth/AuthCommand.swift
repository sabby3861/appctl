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
        init() {}

        func run() async throws {
            let output = OutputFormatter()
            let keyID = try keyId ?? promptRequired("API Key ID")
            let issuerID = try issuerId ?? promptRequired("Issuer ID")
            let keyPath = try privateKeyPath ?? promptRequired("Path to .p8 key file")
            let resolved = (keyPath as NSString).expandingTildeInPath
            output.info("Validating private key...")
            switch AuthStore.validateKeyFile(at: resolved) {
            case .success: output.success("Private key is valid")
            case .failure(let error):
                output.error(error.diagnosticMessage)
                throw error
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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Verifying credentials")
            do {
                let r: APIListResponse<App> = try await client.getList(
                    "apps", queryItems: [URLQueryItem(name: "limit", value: "1")])
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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let config = try globals.resolvedConfig()
            let masked = config.issuerID.map { id in id.count > 8 ? "\(id.prefix(4))…\(id.suffix(4))" : id }
            let source: String
            if ProcessInfo.processInfo.environment["APPCTL_KEY_ID"] != nil {
                source = "Environment variables"
            } else if FileManager.default.fileExists(atPath: ".appctl.toml") {
                source = ".appctl.toml (project)"
            } else {
                source = "None found"
            }
            output.printDetail(fields: [
                ("Key ID:", config.keyID ?? "Not configured"),
                ("Issuer ID:", masked ?? "Not configured"), ("Key File:", config.privateKeyPath ?? "Not configured"),
                ("Config Source:", source), ("CI Environment:", ConfigLoader.isCI() ? "Yes" : "No"),
            ])
        }
    }
}

/// Shared `--key-id`, `--issuer-id`, `--format`, `--verbose`, `--no-color` flags
/// composed into command groups via `@OptionGroup`. Internal because no SemVer
/// commitment is intended outside the AppctlCore module.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "API Key ID.") var keyId: String?
    @Option(name: .long, help: "Issuer ID.") var issuerId: String?
    @Option(name: .long, help: "Path to .p8 key file.") var privateKeyPath: String?
    @Option(name: .long, help: "Output format: text, json, table, csv.") var format: String?
    @Flag(name: .long, help: "Show verbose output.") var verbose = false
    @Flag(name: .long, help: "Disable colored output.") var noColor = false
    init() {}

    var resolvedFormat: OutputFormat {
        if let f = format { return OutputFormat(rawValue: f) ?? .text }
        return (!ConfigLoader.isTerminal() || ConfigLoader.isCI()) ? .json : .text
    }

    func resolvedConfig() throws -> AppctlConfig {
        try ConfigLoader.load(
            keyIDOverride: keyId, issuerIDOverride: issuerId,
            privateKeyPathOverride: privateKeyPath, formatOverride: format,
            verboseOverride: verbose, noColorOverride: noColor)
    }

    func apiClient() throws -> (any AppStoreConnectClient, AppctlConfig) {
        let config = try resolvedConfig()
        let gen = try AuthStore.createGenerator(from: config)
        return (APIClient(jwtGenerator: gen, verbose: config.verbose, timeout: config.timeout), config)
    }
}
