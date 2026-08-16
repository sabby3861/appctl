import ArgumentParser
import Foundation

public struct AppsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "apps", abstract: "List and manage apps.",
        subcommands: [List.self, Info.self], defaultSubcommand: List.self)
    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all apps.")
        @Option(name: .long, help: "Filter by bundle ID.") var bundleId: String?
        @Option(name: .long, help: "Filter by name.") var name: String?
        @OptionGroup var pagination: PaginationOptions
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            try await Self.execute(
                client: client, output: output, bundleId: bundleId, name: name,
                limit: pagination.limit, pageSize: pagination.pageSize)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter,
            bundleId: String?, name: String?, limit: Int?, pageSize: Int
        ) async throws {
            try PaginationOptions.validate(limit: limit, pageSize: pageSize)
            let spinner = output.startSpinner("Fetching apps")
            var q: [URLQueryItem] = [
                URLQueryItem(name: "fields[apps]", value: "name,bundleId,sku,primaryLocale")
            ]
            if let b = bundleId { q.append(URLQueryItem(name: "filter[bundleId]", value: b)) }
            if let n = name { q.append(URLQueryItem(name: "filter[name]", value: n)) }
            do {
                let r: APIListResponse<App> = try await client.getList(
                    "apps", queryItems: q, limit: limit, pageSize: pageSize)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id }, Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Bundle ID") { $0.attributes?.bundleId ?? "—" },
                        Column(header: "SKU") { $0.attributes?.sku ?? "—" },
                        Column(header: "Locale") { $0.attributes?.primaryLocale ?? "—" },
                    ], emptyMessage: "No apps found.")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show detailed app information.")
        @Argument(help: "App ID or Bundle ID.") var identifier: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching app details")
            do {
                let app: App
                if identifier.contains(".") {
                    let r: APIListResponse<App> = try await client.getList(
                        "apps",
                        queryItems: [URLQueryItem(name: "filter[bundleId]", value: identifier)],
                        limit: 1, pageSize: 1)
                    guard let found = r.data.first else {
                        spinner.stop(success: false)
                        throw AppctlError.resourceNotFound(type: "App", identifier: identifier)
                    }
                    app = found
                } else {
                    let r: APIResponse<App> = try await client.get("apps/\(identifier)")
                    app = r.data
                }
                spinner.stop()
                let a = app.attributes
                output.printDetail(fields: [
                    ("ID:", app.id), ("Name:", a?.name ?? "—"), ("Bundle ID:", a?.bundleId ?? "—"),
                    ("SKU:", a?.sku ?? "—"), ("Primary Locale:", a?.primaryLocale ?? "—"),
                    ("Made for Kids:", a?.isOrEverWasMadeForKids.map { $0 ? "Yes" : "No" } ?? "—"),
                ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
