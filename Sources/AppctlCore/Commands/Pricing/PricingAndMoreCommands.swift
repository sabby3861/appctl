import ArgumentParser
import Foundation

// MARK: - Pricing
public struct PricingCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pricing",
        abstract: "Inspect App Store territory and availability settings.",
        discussion: "Note: per-territory price tiers are not yet implemented. `info` shows availability flags only.",
        subcommands: [Info.self, Territories.self],
        defaultSubcommand: Info.self
    )
    public init() {}
    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show territory-availability flags for an app.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            try await Self.execute(client: client, output: output, appId: id)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId id: String
        ) async throws {
            let spinner = output.startSpinner("Fetching availability settings")
            do {
                let r: APIResponse<App> = try await client.get(
                    "apps/\(id)",
                    queryItems: [URLQueryItem(name: "fields[apps]", value: "name,availableInNewTerritories")]
                )
                spinner.stop()
                output.printDetail(fields: [
                    ("App:", r.data.attributes?.name ?? "—"),
                    ("Auto-add new territories:", r.data.attributes?.availableInNewTerritories == true ? "Yes" : "No"),
                ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
    struct Territories: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List App Store territories.")
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
            let spinner = output.startSpinner("Fetching territories")
            do {
                let r: APIListResponse<Territory> = try await client.getList(
                    "territories",
                    queryItems: [URLQueryItem(name: "fields[territories]", value: "currency")])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id }, Column(header: "Currency") { $0.attributes?.currency ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
struct Territory: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: TerritoryAttributes?
}
struct TerritoryAttributes: Decodable { let currency: String? }

// MARK: - IAP
public struct IAPCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "iap", abstract: "Manage in-app purchases.", subcommands: [ListIAP.self, SubscriptionGroups.self],
        defaultSubcommand: ListIAP.self)
    public init() {}
    struct ListIAP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List in-app purchases.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            try await Self.execute(client: client, output: output, appId: id)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId id: String
        ) async throws {
            let spinner = output.startSpinner("Fetching IAPs")
            do {
                let r: APIListResponse<InAppPurchase> = try await client.getList(
                    "apps/\(id)/inAppPurchasesV2",
                    queryItems: [
                        URLQueryItem(name: "fields[inAppPurchases]", value: "name,productId,inAppPurchaseType,state")
                    ])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") { $0.attributes?.name ?? "—" },
                        Column(header: "Product ID") { $0.attributes?.productId ?? "—" },
                        Column(header: "Type") {
                            $0.attributes?.inAppPurchaseType?.replacingOccurrences(of: "_", with: " ") ?? "—"
                        }, Column(header: "State") { $0.attributes?.state ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
    struct SubscriptionGroups: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "subscriptions", abstract: "List subscription groups.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            try await Self.execute(client: client, output: output, appId: id)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId id: String
        ) async throws {
            let spinner = output.startSpinner("Fetching subscriptions")
            do {
                let r: APIListResponse<SubscriptionGroup> = try await client.getList(
                    "apps/\(id)/subscriptionGroups",
                    queryItems: [URLQueryItem(name: "fields[subscriptionGroups]", value: "referenceName")])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Name") { $0.attributes?.referenceName ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
struct InAppPurchase: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: InAppPurchaseAttributes?
}
struct InAppPurchaseAttributes: Decodable {
    let name: String?
    let productId: String?
    let inAppPurchaseType: String?
    let state: String?
}
struct SubscriptionGroup: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: SubscriptionGroupAttributes?
}
struct SubscriptionGroupAttributes: Decodable { let referenceName: String? }

// MARK: - Users
public struct UsersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "users", abstract: "Manage team members.", subcommands: [List.self, Roles.self],
        defaultSubcommand: List.self)
    public init() {}
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List team members.")
        @Option(name: .long, help: "Filter by role.") var role: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output, role: role)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, role: String?
        ) async throws {
            let spinner = output.startSpinner("Fetching users")
            var q: [URLQueryItem] = [URLQueryItem(name: "fields[users]", value: "firstName,lastName,email,roles")]
            if let r = role { q.append(URLQueryItem(name: "filter[roles]", value: r.uppercased())) }
            do {
                let r: APIListResponse<User> = try await client.getList("users", queryItems: q)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Name") {
                            "\($0.attributes?.firstName ?? "") \($0.attributes?.lastName ?? "")".trimmingCharacters(
                                in: .whitespaces)
                        },
                        Column(header: "Email") { $0.attributes?.email ?? "—" },
                        Column(header: "Roles") { $0.attributes?.roles?.joined(separator: ", ") ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
    struct Roles: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available roles.")
        func run() throws {
            Self.execute(output: OutputFormatter())
        }

        static func execute(output: OutputFormatter) {
            for (r, d) in [
                ("ADMIN", "Full access"), ("DEVELOPER", "Manage builds/TestFlight"), ("MARKETING", "App metadata"),
                ("FINANCE", "Financial reports"), ("SALES", "Sales reports"),
            ] { output.info("  \(r.padded(to: 14)) \(d)") }
        }
    }
}
struct User: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: UserAttributes?
}
struct UserAttributes: Decodable {
    let firstName: String?
    let lastName: String?
    let email: String?
    let roles: [String]?
}

// MARK: - Reviews
public struct ReviewCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reviews", abstract: "Manage customer reviews.",
        subcommands: [CustomerReviews.self, RespondReview.self], defaultSubcommand: CustomerReviews.self)
    public init() {}
    struct CustomerReviews: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List customer reviews.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Filter by rating (1-5).") var rating: Int?
        @OptionGroup var pagination: PaginationOptions
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            try await Self.execute(
                client: client, output: output, appId: id, rating: rating,
                limit: pagination.limit, pageSize: pagination.pageSize)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId id: String,
            rating: Int?, limit: Int?, pageSize: Int
        ) async throws {
            try PaginationOptions.validate(limit: limit, pageSize: pageSize)
            let spinner = output.startSpinner("Fetching reviews")
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[customerReviews]", value: "rating,title,body,reviewerNickname,createdDate,territory"),
                URLQueryItem(name: "sort", value: "-createdDate"),
            ]
            if let r = rating, (1...5).contains(r) { q.append(URLQueryItem(name: "filter[rating]", value: String(r))) }
            do {
                let r: APIListResponse<CustomerReview> = try await client.getList(
                    "apps/\(id)/customerReviews", queryItems: q, limit: limit, pageSize: pageSize)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "Rating") {
                            let r = $0.attributes?.rating ?? 0
                            return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
                        },
                        Column(header: "Title") { $0.attributes?.title?.truncated(to: 30) ?? "—" },
                        Column(header: "Reviewer") { $0.attributes?.reviewerNickname ?? "—" },
                        Column(header: "Date") { $0.attributes?.createdDate?.formattedDate() ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
    struct RespondReview: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "respond", abstract: "Respond to a review.")
        @Argument(help: "Review ID.") var reviewId: String
        @Option(name: .long, help: "Response text.") var response: String
        @Flag(name: .long, help: "Preview.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            if let outcome = try await Self.execute(
                client: client, output: output, reviewId: reviewId, response: response,
                dryRun: dryRun)
            {
                output.printMutation(outcome)
            }
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, reviewId: String,
            response: String, dryRun: Bool
        ) async throws -> MutationOutcome? {
            if response.count > 5970 {
                throw AppctlError.invalidInput(
                    field: "response", value: "\(response.count) chars", expected: "Max 5970")
            }
            if dryRun {
                output.info("[DRY RUN] Would respond to review \(reviewId)")
                return nil
            }
            let spinner = output.startSpinner("Posting response")
            struct RRReq: Encodable { let data: RRData }
            struct RRData: Encodable {
                let type: String
                let attributes: RRAttr
                let relationships: RRRel
            }
            struct RRAttr: Encodable { let responseBody: String }
            struct RRRel: Encodable { let review: RelationshipRef }
            struct RRResp: Decodable, Identifiable {
                let type: String
                let id: String
            }
            let body = RRReq(
                data: RRData(
                    type: "customerReviewResponses", attributes: RRAttr(responseBody: response),
                    relationships: RRRel(
                        review: RelationshipRef(data: TypeIDRef(type: "customerReviews", id: reviewId)))))
            do {
                let r: APIResponse<RRResp> = try await client.post("customerReviewResponses", body: body)
                spinner.stop()
                output.success("Response posted")
                return MutationOutcome(
                    data: .object([
                        "review_id": .string(reviewId),
                        "response_id": .string(r.data.id),
                    ]))
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
struct CustomerReview: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: CustomerReviewAttributes?
}
struct CustomerReviewAttributes: Decodable {
    let rating: Int?
    let title: String?
    let body: String?
    let reviewerNickname: String?
    let createdDate: String?
    let territory: String?
}
