import ArgumentParser
import Foundation

public enum AppctlVersion { public static let current = "0.1.0" }

public struct VersionCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "version", abstract: "Show appctl version.")
    @Flag(name: .long, help: "Version number only.") var short = false
    public init() {}
    public func run() throws {
        if short {
            print(AppctlVersion.current)
        } else {
            print(
                "appctl \(AppctlVersion.current)\nSwift CLI for App Store Connect\nhttps://github.com/sabby3861/appctl")
        }
    }
}

public struct InitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Create a new .appctl.toml configuration file.")
    @Flag(name: .long, help: "Show example config without writing.") var example = false
    @Flag(name: .long, help: "Overwrite existing config.") var force = false
    public init() {}
    public func run() throws {
        let output = OutputFormatter()
        if example {
            print(ConfigLoader.exampleConfig())
            return
        }
        if FileManager.default.fileExists(atPath: ".appctl.toml") && !force {
            output.warning(".appctl.toml already exists. Use --force to overwrite.")
            return
        }
        try ConfigLoader.exampleConfig().write(toFile: ".appctl.toml", atomically: true, encoding: .utf8)
        output.success("Created .appctl.toml")
        output.info("Edit the file or run `appctl auth setup`.")
    }
}
