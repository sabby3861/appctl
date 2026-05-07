import ArgumentParser
import Foundation

// MARK: - Screenshots
public struct ScreenshotsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshots", abstract: "Manage App Store screenshots.", subcommands: [List.self, Delete.self],
        defaultSubcommand: List.self)
    public init() {}
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
