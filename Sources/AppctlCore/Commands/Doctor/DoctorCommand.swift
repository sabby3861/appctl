import ArgumentParser
import Foundation

public struct DoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Validate your environment and diagnose issues.")
    @OptionGroup var globals: GlobalOptions
    public init() {}
    public func run() async throws {
        let output = try globals.outputFormatter()
        let config = try ConfigLoader.load(
            keyIDOverride: globals.keyId, issuerIDOverride: globals.issuerId,
            privateKeyPathOverride: globals.privateKeyPath)
        // nil when auth isn't configured — diagnostics then skip the connectivity check.
        let client = (try? globals.apiClient(timeout: 10))?.0
        try await Self.execute(client: client, output: output, config: config)
    }

    static func execute(
        client: (any AppStoreConnectClient)?, output: OutputFormatter, config: AppctlConfig
    ) async throws {
        var s = StandardError.shared
        print("\n  \(output.useColor ? "\u{001B}[1mappctl doctor\u{001B}[0m" : "appctl doctor")", to: &s)
        print("  Checking your environment...\n", to: &s)
        let results = await EnvironmentDiagnostics.runAll(config: config, client: client)
        for result in results {
            let sym: String
            if output.useColor {
                switch result.status {
                case .pass: sym = "\u{001B}[32m✓\u{001B}[0m"
                case .warn: sym = "\u{001B}[33m⚠\u{001B}[0m"
                case .fail: sym = "\u{001B}[31m✗\u{001B}[0m"
                case .skip: sym = "\u{001B}[90m○\u{001B}[0m"
                }
            } else {
                sym = result.status.rawValue
            }
            print("  \(sym) \(result.name): \(result.detail)", to: &s)
            if let fix = result.fix { print("    └─ \(fix)", to: &s) }
        }
        let passed = results.filter { $0.status == .pass }.count
        let warnings = results.filter { $0.status == .warn }.count
        let failures = results.filter { $0.status == .fail }.count
        print("", to: &s)
        if failures == 0 && warnings == 0 {
            output.success("All checks passed!")
        } else if failures == 0 {
            output.warning("\(passed) passed, \(warnings) warning(s).")
        } else {
            output.error("\(passed) passed, \(warnings) warning(s), \(failures) issue(s) need attention.")
            // Exit non-zero so CI can detect a broken environment without re-printing the summary.
            throw ArgumentParser.ExitCode.failure
        }
    }
}
