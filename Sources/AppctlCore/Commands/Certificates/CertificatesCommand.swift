import ArgumentParser
import Foundation

public struct CertificatesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "certificates", abstract: "Manage signing certificates and profiles.",
        subcommands: [List.self, Profiles.self, Devices.self, BundleIDs.self], defaultSubcommand: List.self)
    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List certificates with expiry status.")
        @Option(name: .long, help: "Filter by type.") var type: String?
        @Flag(name: .long, help: "Show only expiring within 30 days.") var expiringSoon = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(
                client: client, output: output, type: type, expiringSoon: expiringSoon)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, type: String?,
            expiringSoon: Bool
        ) async throws {
            let spinner = output.startSpinner("Fetching certificates")
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[certificates]",
                    value: "name,certificateType,displayName,serialNumber,platform,expirationDate")
            ]
            if let t = type { q.append(URLQueryItem(name: "filter[certificateType]", value: t.uppercased())) }
            do {
                let r: APIListResponse<Certificate> = try await client.getList("certificates", queryItems: q)
                spinner.stop()
                let certs = expiringSoon ? r.data.filter(Self.isExpiringSoon) : r.data
                output.printList(
                    certs,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Name") { $0.attributes?.displayName ?? $0.attributes?.name ?? "—" },
                        Column(header: "Type") { $0.attributes?.certificateType?.certificateTypeDisplay ?? "—" },
                        Column(header: "Serial") { $0.attributes?.serialNumber ?? "—" },
                        Column(header: "Expires") { Self.expiryDisplay($0) },
                    ])
                if !expiringSoon {
                    let expiring = r.data.filter(Self.isExpiringSoon)
                    if !expiring.isEmpty {
                        output.warning(
                            "\(expiring.count) certificate(s) expiring within \(Self.expiringSoonDays) days!")
                    }
                }
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }

        /// Window before expiry where we surface a warning.
        static let expiringSoonDays = 30

        static func isExpiringSoon(_ cert: Certificate) -> Bool {
            guard let days = cert.attributes?.expirationDate?.daysUntil else { return false }
            return days >= 0 && days <= expiringSoonDays
        }

        private static func expiryDisplay(_ cert: Certificate) -> String {
            guard let days = cert.attributes?.expirationDate?.daysUntil else { return "—" }
            if days < 0 { return "❌ Expired" }
            if days <= 7 { return "🔴 \(days)d" }
            if days <= expiringSoonDays { return "🟡 \(days)d" }
            return "🟢 \(days)d"
        }
    }

    struct Profiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List provisioning profiles.")
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter
        ) async throws {
            let spinner = output.startSpinner("Fetching profiles")
            do {
                let r: APIListResponse<Profile> = try await client.getList(
                    "profiles",
                    queryItems: [
                        URLQueryItem(
                            name: "fields[profiles]", value: "name,profileType,profileState,platform,expirationDate")
                    ])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Type") {
                            $0.attributes?.profileType?.replacingOccurrences(of: "_", with: " ") ?? "—"
                        },
                        Column(header: "State") {
                            $0.attributes?.profileState == "ACTIVE" ? "✅ Active" : ($0.attributes?.profileState ?? "—")
                        },
                        Column(header: "Expires") { $0.attributes?.expirationDate?.formattedDate() ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Devices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered devices.")
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter
        ) async throws {
            let spinner = output.startSpinner("Fetching devices")
            do {
                let r: APIListResponse<Device> = try await client.getList(
                    "devices",
                    queryItems: [
                        URLQueryItem(name: "fields[devices]", value: "name,platform,udid,deviceClass,status,model")
                    ])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Model") { $0.attributes?.model ?? "—" },
                        Column(header: "UDID") { $0.attributes?.udid?.truncated(to: 16) ?? "—" },
                        Column(header: "Status") { $0.attributes?.status ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct BundleIDs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bundle-ids", abstract: "List bundle identifiers.")
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter
        ) async throws {
            let spinner = output.startSpinner("Fetching bundle IDs")
            do {
                let r: APIListResponse<BundleID> = try await client.getList(
                    "bundleIds",
                    queryItems: [URLQueryItem(name: "fields[bundleIds]", value: "name,identifier,platform")])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Identifier") { $0.attributes?.identifier ?? "—" },
                        Column(header: "Platform") { $0.attributes?.platform ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
