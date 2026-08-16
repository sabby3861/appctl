import ArgumentParser
import Foundation

public struct BuildsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "builds", abstract: "List and manage builds.",
        subcommands: [List.self, Info.self, SetCompliance.self], defaultSubcommand: List.self)
    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List builds for an app.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Filter by state: PROCESSING, FAILED, INVALID, VALID.") var state: String?
        @Option(name: .long, help: "Filter by version.") var version: String?
        @OptionGroup var pagination: PaginationOptions
        @Flag(name: .long, help: "Show only expired.") var expired = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            try await Self.execute(
                client: client, output: output, appId: appId ?? config.defaultAppID,
                state: state, version: version, limit: pagination.limit,
                pageSize: pagination.pageSize, expired: expired)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId: String?,
            state: String?, version: String?, limit: Int?, pageSize: Int, expired: Bool
        ) async throws {
            try PaginationOptions.validate(limit: limit, pageSize: pageSize)
            let spinner = output.startSpinner("Fetching builds")
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[builds]",
                    value:
                        "version,uploadedDate,expirationDate,expired,minOsVersion,processingState,usesNonExemptEncryption"
                ), URLQueryItem(name: "sort", value: "-uploadedDate"),
            ]
            if let a = appId { q.append(URLQueryItem(name: "filter[app]", value: a)) }
            if let s = state { q.append(URLQueryItem(name: "filter[processingState]", value: s.uppercased())) }
            if let v = version { q.append(URLQueryItem(name: "filter[version]", value: v)) }
            if expired { q.append(URLQueryItem(name: "filter[expired]", value: "true")) }
            do {
                let r: APIListResponse<Build> = try await client.getList(
                    "builds", queryItems: q, limit: limit, pageSize: pageSize)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Version") { $0.attributes?.version ?? "—" },
                        Column(header: "State") { $0.attributes?.processingState?.processingStateDisplay ?? "—" },
                        Column(header: "Uploaded") { $0.attributes?.uploadedDate?.formattedDate() ?? "—" },
                        Column(header: "Compliance") {
                            $0.attributes?.usesNonExemptEncryption == nil
                                ? "⚠ Missing" : ($0.attributes?.usesNonExemptEncryption == true ? "🔐 Yes" : "✅ Exempt")
                        },
                        Column(header: "Expired") { $0.attributes?.expired == true ? "Yes" : "No" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show detailed build information.")
        @Argument(help: "Build ID.") var buildId: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching build details")
            do {
                let r: APIResponse<Build> = try await client.get("builds/\(buildId)")
                spinner.stop()
                let a = r.data.attributes
                output.printDetail(fields: [
                    ("ID:", r.data.id), ("Version:", a?.version ?? "—"),
                    ("State:", a?.processingState?.processingStateDisplay ?? "—"),
                    ("Uploaded:", a?.uploadedDate?.formattedDate() ?? "—"),
                    ("Expiration:", a?.expirationDate?.formattedDate() ?? "—"), ("Min OS:", a?.minOsVersion ?? "—"),
                    (
                        "Encryption:",
                        a?.usesNonExemptEncryption == nil
                            ? "⚠ Not declared" : (a?.usesNonExemptEncryption == true ? "Non-exempt" : "Exempt")
                    ),
                ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct SetCompliance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-compliance", abstract: "Declare export compliance for a build.")
        @Argument(help: "Build ID.") var buildId: String
        @Flag(name: .long, help: "App uses non-exempt encryption.") var usesEncryption = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Setting export compliance")
            let body = ComplianceUpdateRequest(
                data: ComplianceUpdateData(
                    type: "builds", id: buildId,
                    attributes: ComplianceUpdateAttributes(usesNonExemptEncryption: usesEncryption)))
            do {
                let _: APIResponse<Build> = try await client.patch("builds/\(buildId)", body: body)
                spinner.stop()
                output.success(
                    usesEncryption
                        ? "Compliance declared: uses non-exempt encryption"
                        : "Compliance declared: exempt (standard HTTPS only)")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
