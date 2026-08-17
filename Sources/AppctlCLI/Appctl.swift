import AppctlCore
import ArgumentParser
import Foundation

@main
struct Appctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appctl",
        abstract: "The Swift CLI for App Store Connect. Zero Ruby. Zero friction.",
        discussion: """
            Get started:
              appctl auth setup        Configure API credentials
              appctl doctor            Check your environment
              appctl apps list         List your apps

            Workflows:
              appctl workflow release  Full release pipeline
              appctl workflow publish  TestFlight distribution
              appctl workflow watch    Real-time status monitoring
              appctl ai release-notes  Generate notes from git

            Docs: https://github.com/sabby3861/appctl
            """,
        version: AppctlVersion.current,
        subcommands: [
            AuthCommand.self, AppsCommand.self, BuildsCommand.self, VersionsCommand.self,
            TestFlightCommand.self, CertificatesCommand.self, LocalizationsCommand.self,
            MetadataCommand.self, ScreenshotsCommand.self, ReviewCommand.self,
            IAPCommand.self, PricingCommand.self,
            UsersCommand.self, WorkflowCommand.self, AICommand.self, PluginCommand.self,
            APICommand.self, DoctorCommand.self, InitCommand.self, VersionCommand.self,
            CompletionsCommand.self,
        ],
        defaultSubcommand: nil
    )

    /// Custom entry point: parse and run exactly as `AsyncParsableCommand.main()`
    /// would, but route failures through the stable error taxonomy so the exit
    /// code carries the class (1 usage, 2 validation, 3 API, 4 auth, 5 network)
    /// and `--output json` gets an error envelope on stdout. Anything the
    /// taxonomy doesn't cover (help, --version, explicit ExitCode throws) falls
    /// back to ArgumentParser's own handling.
    static func main() async {
        do {
            var command = try parseAsRoot(nil)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            let arguments = Array(CommandLine.arguments.dropFirst())
            // ArgumentParser reports its parse/validation failures as EX_USAGE (64).
            let isUsage = exitCode(for: error).rawValue == 64
            if let code = FailureRenderer.render(
                error, arguments: arguments, isUsageError: isUsage,
                usageMessage: fullMessage(for: error))
            {
                Foundation.exit(code)
            }
            exit(withError: error)
        }
    }
}
