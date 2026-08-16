import ArgumentParser
import Foundation

// MARK: - Screenshots
public struct ScreenshotsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshots", abstract: "Manage App Store screenshots.",
        subcommands: [List.self, Upload.self, Delete.self],
        defaultSubcommand: List.self)
    public init() {}

    struct Upload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Upload screenshots from a fastlane-layout directory (<path>/<locale>/*.png|jpg).")
        @Option(name: .long, help: "App ID.") var appId: String
        @Option(name: .long, help: "Version string (e.g. 2.1.0).") var version: String
        @Option(name: .long, help: "Screenshots directory.") var path: String = "./screenshots"
        @Flag(name: .long, help: "Preview without uploading.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            _ = try await Self.execute(
                client: client, output: output, appId: appId, version: version,
                path: path, dryRun: dryRun)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter,
            appId: String, version: String, path: String, dryRun: Bool,
            retryBaseDelay: TimeInterval = 1.0
        ) async throws -> ScreenshotUploadService.Summary {
            // Every file is validated before the first network request; a single
            // invalid screenshot aborts the whole run with nothing uploaded.
            let validation = try ScreenshotUploadService.validate(
                directory: URL(fileURLWithPath: path))
            for entry in validation.ignored {
                output.info("ignored (unsupported): \(entry)")
            }
            let service = ScreenshotUploadService(client: client, retryBaseDelay: retryBaseDelay)
            let summary = try await service.upload(
                plan: validation.plan, appID: appId, versionString: version,
                dryRun: dryRun, output: output)
            if dryRun {
                output.info("[DRY RUN] \(validation.plan.count) screenshot(s) would be uploaded.")
            } else {
                output.success("Uploaded \(summary.uploadedCount) screenshot(s).")
            }
            return summary
        }
    }
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List screenshot sets.")
        @Option(name: .long, help: "Version ID.") var versionId: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching screenshots")
            do {
                let r: APIListResponse<ScreenshotSet> = try await client.getList(
                    "appStoreVersions/\(versionId)/appScreenshotSets",
                    queryItems: [URLQueryItem(name: "fields[appScreenshotSets]", value: "screenshotDisplayType")])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Display Type") {
                            $0.attributes?.screenshotDisplayType?.displayTypeLabel ?? "—"
                        },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a screenshot.")
        @Argument(help: "Screenshot ID.") var screenshotId: String
        @Flag(name: .long, help: "Preview.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            if dryRun {
                output.info("[DRY RUN] Would delete screenshot \(screenshotId)")
                return
            }
            let spinner = output.startSpinner("Deleting screenshot")
            do {
                try await client.delete("appScreenshots/\(screenshotId)")
                spinner.stop()
                output.success("Screenshot deleted")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
struct ScreenshotSet: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: ScreenshotSetAttributes?
}
struct ScreenshotSetAttributes: Decodable { let screenshotDisplayType: String? }
