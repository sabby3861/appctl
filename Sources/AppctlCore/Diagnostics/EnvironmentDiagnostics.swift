import Foundation

public struct EnvironmentDiagnostics {
    public struct CheckResult: Sendable {
        public let name: String
        public let status: Status
        public let detail: String
        public let fix: String?
        public enum Status: String, Sendable {
            case pass = "✓"
            case warn = "⚠"
            case fail = "✗"
            case skip = "○"
        }
        public init(name: String, status: Status, detail: String, fix: String? = nil) {
            self.name = name
            self.status = status
            self.detail = detail
            self.fix = fix
        }
    }

    /// `client` is nil when auth isn't configured; the connectivity check is skipped
    /// rather than constructed here, so the composition root stays the only place a
    /// concrete client is built.
    public static func runAll(config: AppctlConfig, client: (any AppStoreConnectClient)?) async -> [CheckResult] {
        var r: [CheckResult] = []
        r.append(checkSwift())
        r.append(checkXcode())
        r.append(checkAuth(config: config))
        r.append(await checkAPI(client: client))
        r.append(checkConfig(config: config))
        r.append(checkUploadBackends(config: config))
        r.append(checkNetwork())
        r.append(checkDisk())
        return r
    }

    /// Reports which `builds upload` backends are usable: the Build Upload API needs
    /// configured auth; altool needs Xcode's tools on the path.
    static func checkUploadBackends(config: AppctlConfig) -> CheckResult {
        let apiAvailable = config.keyID != nil && config.issuerID != nil
        let altoolPath = shell("xcrun -f altool 2>/dev/null")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let altoolAvailable = altoolPath.map { !$0.isEmpty } ?? false
        let detail =
            "api: \(apiAvailable ? "available" : "needs auth setup"), "
            + "altool: \(altoolAvailable ? "available" : "not found")"
        if apiAvailable && altoolAvailable {
            return CheckResult(name: "Upload Backends", status: .pass, detail: detail)
        }
        return CheckResult(
            name: "Upload Backends", status: apiAvailable || altoolAvailable ? .warn : .fail,
            detail: detail,
            fix: apiAvailable
                ? "Install Xcode to enable the altool backend."
                : "Run `appctl auth setup` to enable the API backend.")
    }

    static func checkSwift() -> CheckResult {
        if let o = shell("swift --version"), o.contains("Swift version") {
            return CheckResult(
                name: "Swift", status: .pass,
                detail: o.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "installed")
        }
        return CheckResult(
            name: "Swift", status: .fail, detail: "Swift not found", fix: "Install Xcode or run: xcode-select --install"
        )
    }

    static func checkXcode() -> CheckResult {
        if let o = shell("xcodebuild -version"), o.contains("Xcode") {
            return CheckResult(
                name: "Xcode", status: .pass,
                detail: o.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "installed")
        }
        return CheckResult(
            name: "Xcode", status: .warn, detail: "Full Xcode not found", fix: "Install from Mac App Store")
    }

    static func checkAuth(config: AppctlConfig) -> CheckResult {
        guard let keyID = config.keyID, !keyID.isEmpty else {
            return CheckResult(
                name: "Authentication", status: .fail, detail: "No API Key ID", fix: "Run `appctl auth setup`")
        }
        guard config.issuerID != nil else {
            return CheckResult(
                name: "Authentication", status: .fail, detail: "No Issuer ID", fix: "Run `appctl auth setup`")
        }
        guard let keyPath = config.privateKeyPath else {
            return CheckResult(
                name: "Authentication", status: .fail, detail: "No private key path", fix: "Run `appctl auth setup`")
        }
        switch AuthStore.validateKeyFile(at: keyPath) {
        case .success:
            return CheckResult(name: "Authentication", status: .pass, detail: "API Key \(keyID) with valid .p8 key")
        case .failure(let e): return CheckResult(name: "Authentication", status: .fail, detail: e.diagnosticMessage)
        }
    }

    static func checkAPI(client: (any AppStoreConnectClient)?) async -> CheckResult {
        guard let client else {
            return CheckResult(name: "API Connectivity", status: .skip, detail: "Skipped (auth not configured)")
        }
        do {
            let _: APIListResponse<App> = try await client.getList("apps", limit: 1, pageSize: 1)
            return CheckResult(name: "API Connectivity", status: .pass, detail: "Connected to App Store Connect API")
        } catch {
            return CheckResult(
                name: "API Connectivity", status: .fail, detail: "Cannot reach API: \(error.localizedDescription)")
        }
    }

    static func checkConfig(config: AppctlConfig) -> CheckResult {
        if FileManager.default.fileExists(atPath: ".appctl.toml") {
            return CheckResult(name: "Configuration", status: .pass, detail: "Project config found")
        }
        return CheckResult(
            name: "Configuration", status: .warn, detail: "No config file found", fix: "Run `appctl init`")
    }

    static func checkNetwork() -> CheckResult {
        if let o = shell("host api.appstoreconnect.apple.com 2>/dev/null"), o.contains("has address") {
            return CheckResult(name: "Network", status: .pass, detail: "api.appstoreconnect.apple.com reachable")
        }
        return CheckResult(
            name: "Network", status: .fail, detail: "Cannot reach API host", fix: "Check internet and firewall")
    }

    static func checkDisk() -> CheckResult {
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: FileManager.default.homeDirectoryForCurrentUser.path),
            let free = attrs[.systemFreeSize] as? Int64
        {
            let gb = Double(free) / 1_073_741_824
            return CheckResult(
                name: "Disk Space", status: gb < 1.0 ? .warn : .pass, detail: String(format: "%.1f GB available", gb))
        }
        return CheckResult(name: "Disk Space", status: .skip, detail: "Could not determine")
    }

    private static func shell(_ command: String) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }
}
