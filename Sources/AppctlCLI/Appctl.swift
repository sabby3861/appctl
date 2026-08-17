import AppctlCore
import ArgumentParser

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
        ],
        defaultSubcommand: nil
    )
}
