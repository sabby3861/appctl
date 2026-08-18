import ArgumentParser
import Foundation

public enum AppctlVersion { public static let current = "0.1.0" }

public struct VersionCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "version", abstract: "Show appctl version.")
    @Flag(name: .long, help: "Version number only.") var short = false
    public init() {}
    public func run() throws {
        Self.execute(short: short)
    }

    static func execute(short: Bool) {
        if short {
            print(AppctlVersion.current)
        } else {
            print(
                "appctl \(AppctlVersion.current)\nSwift CLI for App Store Connect\nhttps://github.com/sabby3861/appctl")
        }
    }
}
