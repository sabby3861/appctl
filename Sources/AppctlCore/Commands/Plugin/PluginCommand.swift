import ArgumentParser
import Foundation

public struct PluginCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "plugin", abstract: "Manage appctl plugins.", subcommands: [List.self, Run.self, Create.self],
        defaultSubcommand: List.self)
    public init() {}

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed plugins.")
        func run() throws {
            let output = OutputFormatter()
            let plugins = PluginManager.discover()
            if plugins.isEmpty {
                output.info("No plugins found. Create one: `appctl plugin create my-plugin`")
                return
            }
            for p in plugins { output.info("  appctl \(p.name.padded(to: 20)) \(p.path)") }
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a plugin.")
        @Argument(help: "Plugin name.") var name: String
        @Argument(parsing: .captureForPassthrough, help: "Arguments to pass.") var arguments: [String] = []
        init() {}
        func run() throws {
            let plugins = PluginManager.discover()
            guard let plugin = plugins.first(where: { $0.name == name }) else {
                throw AppctlError.resourceNotFound(type: "Plugin", identifier: name)
            }
            let manifest = try PluginManager.manifest(forPluginAt: plugin.path)
            var token: String?
            if manifest?.requiresAPIAccess == true {
                do {
                    let config = try ConfigLoader.load()
                    let generator = try AuthStore.createGenerator(from: config)
                    token = try generator.mintToken(lifetime: PluginManager.pluginTokenLifetime)
                } catch let error as AppctlError {
                    guard case .missingAPIKey(let detail) = error else { throw error }
                    throw AppctlError.missingAPIKey(
                        detail: "Plugin '\(name)' declares API access in its manifest, but \(detail)")
                }
            }
            let process = Process()
            process.executableURL = URL(filePath: plugin.path)
            process.arguments = arguments
            process.environment = PluginManager.childEnvironment(
                base: ProcessInfo.processInfo.environment, token: token)
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            process.standardInput = FileHandle.standardInput
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw AppctlError.unsupportedOperation(
                    name: "plugin \(name)", reason: "Exited with status \(process.terminationStatus)")
            }
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Generate a plugin template.")
        @Argument(help: "Plugin name.") var name: String
        init() {}
        func run() throws {
            let output = OutputFormatter()
            let dir = "appctl-\(name)"
            guard !FileManager.default.fileExists(atPath: dir) else {
                output.warning("'\(dir)' already exists.")
                return
            }
            try FileManager.default.createDirectory(atPath: "\(dir)/Sources", withIntermediateDirectories: true)
            try
                "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"appctl-\(name)\", platforms: [.macOS(.v13)], dependencies: [.package(url: \"https://github.com/apple/swift-argument-parser.git\", from: \"1.3.0\")], targets: [.executableTarget(name: \"appctl-\(name)\", dependencies: [.product(name: \"ArgumentParser\", package: \"swift-argument-parser\")], path: \"Sources\")])"
                .write(toFile: "\(dir)/Package.swift", atomically: true, encoding: .utf8)
            try
                "import ArgumentParser\n@main struct Plugin: ParsableCommand {\n    static let configuration = CommandConfiguration(commandName: \"appctl-\(name)\")\n    func run() throws { print(\"Hello from appctl-\(name)!\") }\n}"
                .write(toFile: "\(dir)/Sources/main.swift", atomically: true, encoding: .utf8)
            output.success("Created plugin template at \(dir)/")
            output.info("Build: cd \(dir) && swift build -c release")
        }
    }
}

enum PluginManager {
    struct PluginInfo: Equatable {
        let name: String
        let path: String
    }

    /// A plugin opts into App Store Connect access with a sidecar manifest next
    /// to its binary: `appctl-<name>.manifest.json` containing
    /// `{"requiresAPIAccess": true}`. Plugins without a manifest get no
    /// credentials of any kind.
    struct Manifest: Decodable, Equatable {
        let requiresAPIAccess: Bool
    }

    /// Maximum lifetime of the delegated token handed to a plugin child process.
    static let pluginTokenLifetime: TimeInterval = 300

    /// Environment keys that must never reach a plugin child process.
    static let credentialEnvironmentKeys: Set<String> = [
        "APPCTL_KEY_ID", "APPCTL_ISSUER_ID", "APPCTL_PRIVATE_KEY_PATH", "APPCTL_PRIVATE_KEY", "APPCTL_TOKEN",
    ]

    /// Returns nil when no manifest exists; throws when one exists but cannot be
    /// parsed, so a typo'd manifest fails loudly instead of silently downgrading
    /// the plugin to no API access.
    static func manifest(forPluginAt path: String) throws -> Manifest? {
        let manifestPath = "\(path).manifest.json"
        guard FileManager.default.fileExists(atPath: manifestPath) else { return nil }
        do {
            let data = try Data(contentsOf: URL(filePath: manifestPath))
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw AppctlError.configParseError(
                path: manifestPath, line: nil,
                reason: "Invalid plugin manifest: \(error.localizedDescription)")
        }
    }

    /// Builds a plugin child environment: strips appctl credential variables and
    /// any value carrying PEM private-key material, then injects at most a
    /// short-lived delegated token.
    static func childEnvironment(base: [String: String], token: String?) -> [String: String] {
        var env = base.filter {
            !credentialEnvironmentKeys.contains($0.key) && !$0.value.contains("PRIVATE KEY-----")
        }
        if let token { env["APPCTL_TOKEN"] = token }
        return env
    }

    /// Discovers plugins by scanning every directory in the current process's `$PATH`.
    static func discover() -> [PluginInfo] {
        let dirs = ProcessInfo.processInfo.environment["PATH"]?.components(separatedBy: ":") ?? []
        return discover(in: dirs)
    }

    /// Discovers plugins in the given list of directories. Extracted so tests can pass
    /// explicit paths instead of mutating the process environment.
    static func discover(in directories: [String]) -> [PluginInfo] {
        var plugins: [PluginInfo] = []
        var seen: Set<String> = []
        for dir in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in entries where file.hasPrefix("appctl-") {
                let name = String(file.dropFirst("appctl-".count))
                let path = "\(dir)/\(file)"
                guard !name.isEmpty, !seen.contains(name),
                    FileManager.default.isExecutableFile(atPath: path)
                else { continue }
                plugins.append(PluginInfo(name: name, path: path))
                seen.insert(name)
            }
        }
        return plugins.sorted { $0.name < $1.name }
    }
}
