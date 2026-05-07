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
            var env = ProcessInfo.processInfo.environment
            if let config = try? ConfigLoader.load() {
                if let k = config.keyID { env["APPCTL_KEY_ID"] = k }
                if let i = config.issuerID { env["APPCTL_ISSUER_ID"] = i }
                if let p = config.privateKeyPath { env["APPCTL_PRIVATE_KEY_PATH"] = p }
            }
            let process = Process()
            process.executableURL = URL(filePath: plugin.path)
            process.arguments = arguments
            process.environment = env
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
