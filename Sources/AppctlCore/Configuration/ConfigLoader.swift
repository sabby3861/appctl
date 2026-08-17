import Foundation

public struct AppctlConfig: Sendable {
    public let keyID: String?
    public let issuerID: String?
    public let privateKeyPath: String?
    /// PEM contents of the .p8 key when it was resolved from the Keychain rather
    /// than a file. When set, it takes precedence over `privateKeyPath`.
    public let privateKeyPEM: String?
    public let defaultAppID: String?
    public let defaultBundleID: String?
    public let outputFormat: OutputFormat
    public let verbose: Bool
    public let noColor: Bool
    public let timeout: TimeInterval

    public init(
        keyID: String? = nil, issuerID: String? = nil, privateKeyPath: String? = nil,
        privateKeyPEM: String? = nil,
        defaultAppID: String? = nil, defaultBundleID: String? = nil,
        outputFormat: OutputFormat = .text, verbose: Bool = false, noColor: Bool = false, timeout: TimeInterval = 30
    ) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPath = privateKeyPath
        self.privateKeyPEM = privateKeyPEM
        self.defaultAppID = defaultAppID
        self.defaultBundleID = defaultBundleID
        self.outputFormat = outputFormat
        self.verbose = verbose
        self.noColor = noColor
        self.timeout = timeout
    }
}

public enum OutputFormat: String, Sendable, CaseIterable { case text, json, table, markdown, csv }

public struct ConfigLoader {
    public static let searchPaths: [String] = {
        var paths = [".appctl.toml"]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            paths.append("\(xdg)/appctl/config.toml")
        }
        paths.append("\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/appctl/config.toml")
        return paths
    }()

    public static func load(
        keyIDOverride: String? = nil, issuerIDOverride: String? = nil,
        privateKeyPathOverride: String? = nil, appIDOverride: String? = nil,
        formatOverride: String? = nil, verboseOverride: Bool = false,
        noColorOverride: Bool = false, keychain: KeychainCredentialStore = KeychainCredentialStore()
    ) throws -> AppctlConfig {
        let fileConfig = loadFromFile()
        let env = ProcessInfo.processInfo.environment
        // Credential resolution order: flags > environment > Keychain > config file.
        // Keychain read failures (locked keychain, headless session) are non-fatal
        // and fall through to the config file.
        let envKeyID = keyIDOverride ?? env["APPCTL_KEY_ID"]
        let envIssuerID = issuerIDOverride ?? env["APPCTL_ISSUER_ID"]
        let envKeyPath = privateKeyPathOverride ?? env["APPCTL_PRIVATE_KEY_PATH"]
        let keyID = envKeyID ?? keychainValue(keychain, .keyID) ?? fileConfig["auth.key_id"]
        let issuerID = envIssuerID ?? keychainValue(keychain, .issuerID) ?? fileConfig["auth.issuer_id"]
        let privateKeyPEM = envKeyPath == nil ? keychainValue(keychain, .privateKey) : nil
        let privateKeyPath = envKeyPath ?? (privateKeyPEM == nil ? fileConfig["auth.private_key_path"] : nil)
        let defaultAppID = appIDOverride ?? env["APPCTL_APP_ID"] ?? fileConfig["app.id"]
        let formatString = formatOverride ?? env["APPCTL_FORMAT"] ?? fileConfig["output.format"] ?? "text"
        let noColor =
            noColorOverride
            || env["NO_COLOR"] != nil
            || fileConfig["output.no_color"] == "true"
            || !isTerminal()
        let verbose =
            verboseOverride
            || env["APPCTL_VERBOSE"] == "1"
            || fileConfig["output.verbose"] == "true"
        let timeout = TimeInterval(fileConfig["network.timeout"] ?? "30") ?? 30
        return AppctlConfig(
            keyID: keyID,
            issuerID: issuerID,
            privateKeyPath: resolveKeyPath(privateKeyPath),
            privateKeyPEM: privateKeyPEM,
            defaultAppID: defaultAppID,
            defaultBundleID: fileConfig["app.bundle_id"],
            outputFormat: OutputFormat(rawValue: formatString) ?? .text,
            verbose: verbose,
            noColor: noColor,
            timeout: timeout
        )
    }

    private static func keychainValue(
        _ store: KeychainCredentialStore, _ account: KeychainCredentialStore.Account
    ) -> String? {
        (try? store.read(account)).flatMap { $0 }
    }

    public static func isTerminal() -> Bool { isatty(STDOUT_FILENO) == 1 }
    public static func isCI() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return [
            "CI", "GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI", "BUILDKITE", "TRAVIS", "JENKINS_URL", "BITRISE_IO",
            "CODEMAGIC",
        ].contains { env[$0] != nil }
    }

    private static func loadFromFile() -> [String: String] {
        for path in searchPaths {
            let resolved = resolvePath(path)
            if let content = try? String(contentsOfFile: resolved, encoding: .utf8) { return parseTOML(content) }
        }
        return [:]
    }

    /// Parses a deliberately small subset of TOML. Values come back as raw `String`
    /// (or omitted if the syntax falls outside the subset); callers coerce to `Bool`,
    /// `Int`, etc. as needed.
    ///
    /// Supported:
    /// - `[section]` headers (single level only — no `[a.b]` nesting, no `[[arrays]]`)
    /// - `key = "string"` (double-quoted) and `key = 'string'` (single-quoted)
    /// - `key = bareword` (anything not starting with a quote, terminated by `#` or end of line)
    /// - End-of-line `# comments`
    /// - Blank lines, leading whitespace
    ///
    /// Not supported (silently ignored or producing odd values — don't rely on these):
    /// - Multi-line strings (`"""..."""`)
    /// - Backslash escapes other than the quote-finder's `\\`
    /// - Arrays (`key = [1, 2]`) — would be stored as the raw string `[1, 2]`
    /// - Inline tables (`key = { a = 1 }`)
    /// - Dotted keys (`a.b = 1`)
    /// - Date/time values
    ///
    /// If you need the full grammar, swap this for [TOMLKit](https://github.com/LebJe/TOMLKit).
    public static func parseTOML(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentSection = ""
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                currentSection = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(
                    in: .whitespaces)
                continue
            }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), let close = findClosingQuote(in: value) {
                    value = String(value[value.index(after: value.startIndex)..<close])
                } else if value.hasPrefix("'"), let close = value.dropFirst().firstIndex(of: "'") {
                    value = String(value[value.index(after: value.startIndex)..<close])
                } else if let hash = value.firstIndex(of: "#") {
                    value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
                }
                guard !key.isEmpty else { continue }
                result[currentSection.isEmpty ? key : "\(currentSection).\(key)"] = value
            }
        }
        return result
    }

    private static func findClosingQuote(in value: String) -> String.Index? {
        var escaped = false
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let ch = value[idx]
            if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { return idx }
            idx = value.index(after: idx)
        }
        return nil
    }

    private static func resolvePath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") { return path }
        return FileManager.default.currentDirectoryPath + "/" + path
    }
    private static func resolveKeyPath(_ path: String?) -> String? { path.map { resolvePath($0) } }

    public static func exampleConfig() -> String {
        """
        # appctl configuration
        [auth]
        # key_id = "XXXXXXXXXX"
        # issuer_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        # private_key_path = "~/.config/appctl/AuthKey.p8"

        [app]
        # id = "1234567890"
        # bundle_id = "com.yourcompany.yourapp"

        [output]
        format = "text"
        verbose = false
        no_color = false

        [network]
        timeout = 30
        """
    }
}
