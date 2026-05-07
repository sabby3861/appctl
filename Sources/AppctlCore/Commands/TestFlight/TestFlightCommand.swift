import ArgumentParser
import Foundation

public struct TestFlightCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "testflight", abstract: "Manage TestFlight beta testing.",
        subcommands: [Groups.self, Testers.self, Distribute.self], defaultSubcommand: Groups.self)
    public init() {}

    struct Groups: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List beta groups.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching beta groups")
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[betaGroups]",
                    value: "name,isInternalGroup,publicLinkEnabled,feedbackEnabled,createdDate")
            ]
            if let a = appId ?? config.defaultAppID { q.append(URLQueryItem(name: "filter[app]", value: a)) }
            do {
                let r: APIListResponse<BetaGroup> = try await client.getList("betaGroups", queryItems: q)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Type") { $0.attributes?.isInternalGroup == true ? "Internal" : "External" },
                        Column(header: "Feedback") { $0.attributes?.feedbackEnabled == true ? "On" : "Off" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Testers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List beta testers.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Filter by email.") var email: String?
        @Option(name: .long, help: "Max results.") var limit: Int = 50
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching testers")
            var q: [URLQueryItem] = [
                URLQueryItem(name: "fields[betaTesters]", value: "firstName,lastName,email,inviteType,state"),
                URLQueryItem(name: "limit", value: String(min(limit, 200))),
            ]
            if let a = appId ?? config.defaultAppID { q.append(URLQueryItem(name: "filter[apps]", value: a)) }
            if let e = email { q.append(URLQueryItem(name: "filter[email]", value: e)) }
            do {
                let r: APIListResponse<BetaTester> = try await client.getList("betaTesters", queryItems: q)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") {
                            "\($0.attributes?.firstName ?? "") \($0.attributes?.lastName ?? "")".trimmingCharacters(
                                in: .whitespaces)
                        },
                        Column(header: "Email") { $0.attributes?.email ?? "—" },
                        Column(header: "State") { $0.attributes?.state ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Distribute: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a build to a beta group.")
        @Argument(help: "Build ID.") var buildId: String
        @Option(name: .long, help: "Beta Group ID.") var groupId: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Distributing build")
            do {
                try await client.postVoid(
                    "betaGroups/\(groupId)/relationships/builds",
                    body: BuildGroupAssignmentBody(data: [TypeIDRef(type: "builds", id: buildId)]))
                spinner.stop()
                output.success("Build \(buildId) added to group \(groupId)")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
