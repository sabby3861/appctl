import ArgumentParser
import Foundation

public struct LocalizationsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "localizations", abstract: "Manage app metadata localizations.",
        subcommands: [List.self, Get.self, Set.self, Sync.self], defaultSubcommand: List.self)
    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List localizations for a version.")
        @Option(name: .long, help: "Version ID.") var versionId: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching localizations")
            do {
                let r: APIListResponse<VersionLocalization> = try await client.getList(
                    "appStoreVersions/\(versionId)/appStoreVersionLocalizations",
                    queryItems: [
                        URLQueryItem(
                            name: "fields[appStoreVersionLocalizations]",
                            value: "locale,description,keywords,whatsNew,promotionalText")
                    ])
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Locale") { $0.attributes?.locale ?? "—" },
                        Column(header: "Description") {
                            $0.attributes?.appDescription.map { "✅ \($0.count)ch" } ?? "❌"
                        },
                        Column(header: "Keywords") { $0.attributes?.keywords.map { "✅ \($0.count)ch" } ?? "❌" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show full metadata for a locale.")
        @Argument(help: "Localization ID.") var localizationId: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching localization")
            do {
                let r: APIResponse<VersionLocalization> = try await client.get(
                    "appStoreVersionLocalizations/\(localizationId)")
                spinner.stop()
                let a = r.data.attributes
                output.printDetail(fields: [
                    ("Locale:", a?.locale ?? "—"), ("Description:", a?.appDescription?.truncated(to: 100) ?? "—"),
                    ("Keywords:", a?.keywords ?? "—"), ("What's New:", a?.whatsNew?.truncated(to: 100) ?? "—"),
                    ("Promotional:", a?.promotionalText?.truncated(to: 80) ?? "—"),
                ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update metadata for a locale.")
        @Argument(help: "Localization ID.") var localizationId: String
        @Option(name: .customLong("description"), help: "App description (max 4000 chars).") var appDescription: String?
        @Option(name: .long, help: "Keywords (max 100 chars).") var keywords: String?
        @Option(name: .long, help: "What's New (max 4000 chars).") var whatsNew: String?
        @Option(name: .long, help: "Promotional text (max 170 chars).") var promotionalText: String?
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            if let d = appDescription, d.count > 4000 {
                throw AppctlError.invalidInput(field: "description", value: "\(d.count) chars", expected: "Max 4000")
            }
            if let k = keywords, k.count > 100 {
                throw AppctlError.invalidInput(field: "keywords", value: "\(k.count) chars", expected: "Max 100")
            }
            if dryRun {
                output.info("[DRY RUN] Would update localization \(localizationId)")
                return
            }
            let spinner = output.startSpinner("Updating localization")
            let body = LocalizationUpdateRequest(
                data: LocalizationUpdateData(
                    type: "appStoreVersionLocalizations", id: localizationId,
                    attributes: LocalizationUpdateAttributes(
                        description: appDescription, keywords: keywords, whatsNew: whatsNew,
                        promotionalText: promotionalText)))
            do {
                let _: APIResponse<VersionLocalization> = try await client.patch(
                    "appStoreVersionLocalizations/\(localizationId)", body: body)
                spinner.stop()
                output.success("Localization updated")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sync metadata between local files and App Store Connect.")
        @Option(name: .long, help: "Version ID.") var versionId: String
        @Option(name: .long, help: "Local directory.") var dir: String = "./metadata"
        @Option(name: .long, help: "Direction: pull or push.") var direction: String = "pull"
        @Flag(name: .long, help: "Preview.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            guard ["pull", "push"].contains(direction) else {
                throw AppctlError.invalidInput(field: "direction", value: direction, expected: "'pull' or 'push'")
            }
            let spinner = output.startSpinner("Fetching localizations")
            let r: APIListResponse<VersionLocalization> = try await client.getList(
                "appStoreVersions/\(versionId)/appStoreVersionLocalizations",
                queryItems: [
                    URLQueryItem(
                        name: "fields[appStoreVersionLocalizations]",
                        value: "locale,description,keywords,whatsNew,promotionalText")
                ])
            spinner.stop()
            if direction == "pull" {
                for loc in r.data {
                    guard let locale = loc.attributes?.locale else { continue }
                    let locDir = "\(dir)/\(locale)"
                    if dryRun {
                        output.info("[DRY RUN] Would write to \(locDir)/")
                        continue
                    }
                    try FileManager.default.createDirectory(atPath: locDir, withIntermediateDirectories: true)
                    if let d = loc.attributes?.appDescription, !d.isEmpty {
                        try d.write(toFile: "\(locDir)/description.txt", atomically: true, encoding: .utf8)
                    }
                    if let k = loc.attributes?.keywords, !k.isEmpty {
                        try k.write(toFile: "\(locDir)/keywords.txt", atomically: true, encoding: .utf8)
                    }
                    if let w = loc.attributes?.whatsNew, !w.isEmpty {
                        try w.write(toFile: "\(locDir)/whats_new.txt", atomically: true, encoding: .utf8)
                    }
                    output.success("Saved \(locale)")
                }
                output.info("Metadata saved to \(dir)/ — track these in git.")
            } else {
                for loc in r.data {
                    guard let locale = loc.attributes?.locale else { continue }
                    let locDir = "\(dir)/\(locale)"
                    guard FileManager.default.fileExists(atPath: locDir) else { continue }
                    // Editors typically append a trailing newline; sending it would surface as
                    // visible whitespace in the App Store metadata.
                    let desc = readTrimmed(at: "\(locDir)/description.txt")
                    let kw = readTrimmed(at: "\(locDir)/keywords.txt")
                    let wn = readTrimmed(at: "\(locDir)/whats_new.txt")
                    guard desc != nil || kw != nil || wn != nil else { continue }
                    if dryRun {
                        output.info("[DRY RUN] Would push \(locale)")
                        continue
                    }
                    let body = LocalizationUpdateRequest(
                        data: LocalizationUpdateData(
                            type: "appStoreVersionLocalizations",
                            id: loc.id,
                            attributes: LocalizationUpdateAttributes(
                                description: desc,
                                keywords: kw,
                                whatsNew: wn,
                                promotionalText: nil
                            )
                        )
                    )
                    do {
                        let _: APIResponse<VersionLocalization> = try await client.patch(
                            "appStoreVersionLocalizations/\(loc.id)",
                            body: body
                        )
                        output.success("Pushed \(locale)")
                    } catch {
                        // TODO(V5): partial push failures still exit 0 — fold into the V5 error-taxonomy/exit-code contract.
                        output.warning("Failed to push \(locale): \(error.localizedDescription)")
                    }
                }
            }
        }

        private func readTrimmed(at path: String) -> String? {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

struct VersionLocalization: Decodable, Identifiable {
    let type: String
    let id: String
    let attributes: VersionLocalizationAttributes?
}
struct VersionLocalizationAttributes: Decodable {
    let locale: String?
    let keywords: String?
    let whatsNew: String?
    let promotionalText: String?
    let appDescription: String?
    let marketingUrl: String?
    let supportUrl: String?
    enum CodingKeys: String, CodingKey {
        case locale
        case appDescription = "description"
        case keywords
        case whatsNew
        case promotionalText
        case marketingUrl
        case supportUrl
    }
}
struct LocalizationUpdateRequest: Encodable { let data: LocalizationUpdateData }
struct LocalizationUpdateData: Encodable {
    let type: String
    let id: String
    let attributes: LocalizationUpdateAttributes
}
struct LocalizationUpdateAttributes: Encodable {
    let description: String?
    let keywords: String?
    let whatsNew: String?
    let promotionalText: String?
    let marketingUrl: String?
    let supportUrl: String?

    init(
        description: String?, keywords: String?, whatsNew: String?, promotionalText: String?,
        marketingUrl: String? = nil, supportUrl: String? = nil
    ) {
        self.description = description
        self.keywords = keywords
        self.whatsNew = whatsNew
        self.promotionalText = promotionalText
        self.marketingUrl = marketingUrl
        self.supportUrl = supportUrl
    }
}
struct LocalizationCreateRequest: Encodable { let data: LocalizationCreateData }
struct LocalizationCreateData: Encodable {
    let type: String
    let attributes: LocalizationCreateAttributes
    let relationships: LocalizationCreateRelationships
}
struct LocalizationCreateAttributes: Encodable {
    let locale: String
    let description: String?
    let keywords: String?
    let whatsNew: String?
    let promotionalText: String?
    let marketingUrl: String?
    let supportUrl: String?

    init(
        locale: String, description: String? = nil, keywords: String? = nil,
        whatsNew: String? = nil, promotionalText: String? = nil,
        marketingUrl: String? = nil, supportUrl: String? = nil
    ) {
        self.locale = locale
        self.description = description
        self.keywords = keywords
        self.whatsNew = whatsNew
        self.promotionalText = promotionalText
        self.marketingUrl = marketingUrl
        self.supportUrl = supportUrl
    }
}
struct LocalizationCreateRelationships: Encodable { let appStoreVersion: RelationshipRef }
