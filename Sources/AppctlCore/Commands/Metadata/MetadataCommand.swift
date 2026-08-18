import ArgumentParser
import Foundation

/// Syncs App Store metadata with local files in the fastlane layout:
/// `<path>/<locale>/<file>.txt`. Only the fastlane files appctl understands are
/// synced (subset policy); anything else in a locale directory is reported as
/// `ignored (unsupported)` — never silently skipped.
///
/// Round-trip contract: `pull` writes each value with exactly one trailing newline;
/// `push` strips exactly one. A pull→push cycle therefore sends values back
/// byte-identical to what the server returned.
public struct MetadataCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "metadata", abstract: "Pull and push App Store metadata as fastlane files.",
        subcommands: [Pull.self, Push.self])
    public init() {}

    /// fastlane file name → appStoreVersionLocalization attribute, in stable order.
    static let fileMap: [(fileName: String, attribute: MetadataAttribute)] = [
        ("description.txt", .description),
        ("keywords.txt", .keywords),
        ("release_notes.txt", .whatsNew),
        ("promotional_text.txt", .promotionalText),
        ("marketing_url.txt", .marketingUrl),
        ("support_url.txt", .supportUrl),
    ]

    enum MetadataAttribute: Sendable {
        case description, keywords, whatsNew, promotionalText, marketingUrl, supportUrl

        func value(in attributes: VersionLocalizationAttributes) -> String? {
            switch self {
            case .description: return attributes.appDescription
            case .keywords: return attributes.keywords
            case .whatsNew: return attributes.whatsNew
            case .promotionalText: return attributes.promotionalText
            case .marketingUrl: return attributes.marketingUrl
            case .supportUrl: return attributes.supportUrl
            }
        }

        /// (limit, field label) for pre-push validation; URLs are unbounded here —
        /// the server validates them.
        var characterLimit: (limit: Int, field: String)? {
            switch self {
            case .description: return (4000, "description")
            case .keywords: return (100, "keywords")
            case .whatsNew: return (4000, "release_notes")
            case .promotionalText: return (170, "promotional_text")
            case .marketingUrl, .supportUrl: return nil
            }
        }
    }

    static let localizationFields = URLQueryItem(
        name: "fields[appStoreVersionLocalizations]",
        value: "locale,description,keywords,whatsNew,promotionalText,marketingUrl,supportUrl")

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write App Store metadata to local fastlane files.")
        @Option(name: .long, help: "App ID.") var appId: String
        @Option(name: .long, help: "Version string (e.g. 2.1.0).") var version: String
        @Option(name: .long, help: "Metadata directory (default: paths.metadata from config, else ./metadata).")
        var path: String?
        @Flag(name: .long, help: "Preview without writing files.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            try await Self.execute(
                client: client, output: output, appId: appId, version: version,
                path: path ?? config.metadataPath ?? "./metadata",
                dryRun: dryRun)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter,
            appId: String, version: String, path: String, dryRun: Bool
        ) async throws {
            let versionID = try await AppStoreVersionResolver.resolveVersionID(
                client: client, appID: appId, versionString: version)
            let localizations: APIListResponse<VersionLocalization> = try await client.getList(
                "appStoreVersions/\(versionID)/appStoreVersionLocalizations",
                queryItems: [MetadataCommand.localizationFields])
            for localization in localizations.data {
                guard let locale = localization.attributes?.locale,
                    let attributes = localization.attributes
                else { continue }
                let localeDir = URL(fileURLWithPath: path).appendingPathComponent(locale)
                if dryRun {
                    output.info("[DRY RUN] Would write to \(localeDir.path)/")
                    continue
                }
                try FileManager.default.createDirectory(
                    at: localeDir, withIntermediateDirectories: true)
                for entry in MetadataCommand.fileMap {
                    guard let value = entry.attribute.value(in: attributes), !value.isEmpty
                    else { continue }
                    let file = localeDir.appendingPathComponent(entry.fileName)
                    do {
                        try (value + "\n").write(to: file, atomically: true, encoding: .utf8)
                    } catch {
                        throw AppctlError.fileWriteError(
                            path: file.path, reason: error.localizedDescription)
                    }
                }
                output.success("Saved \(locale)")
            }
            if !dryRun {
                output.info("Metadata saved to \(path)/ — track these files in git.")
            }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Push local fastlane metadata files to App Store Connect.")
        @Option(name: .long, help: "App ID.") var appId: String
        @Option(name: .long, help: "Version string (e.g. 2.1.0).") var version: String
        @Option(name: .long, help: "Metadata directory (default: paths.metadata from config, else ./metadata).")
        var path: String?
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let summary = try await Self.execute(
                client: client, output: output, appId: appId, version: version,
                path: path ?? config.metadataPath ?? "./metadata",
                dryRun: dryRun)
            if !dryRun {
                output.printMutation(Self.outcome(appId: appId, version: version, summary: summary))
            }
        }

        static func outcome(appId: String, version: String, summary: Summary) -> MutationOutcome {
            MutationOutcome(
                data: .object([
                    "app_id": .string(appId),
                    "version": .string(version),
                    "pushed_locales": .array(summary.pushed.map(JSONValue.string)),
                    "created_locales": .array(summary.created.map(JSONValue.string)),
                    "ignored": .array(summary.ignored.map(JSONValue.string)),
                ]))
        }

        struct LocalePayload: Sendable {
            let locale: String
            let values: [(attribute: MetadataAttribute, value: String)]
        }

        struct Summary: Sendable {
            let pushed: [String]
            let created: [String]
            let ignored: [String]
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter,
            appId: String, version: String, path: String, dryRun: Bool
        ) async throws -> Summary {
            // All local files are read and validated before the first network call.
            let (payloads, ignored) = try scan(directory: URL(fileURLWithPath: path))
            for entry in ignored {
                output.info("ignored (unsupported): \(entry)")
            }

            let versionID = try await AppStoreVersionResolver.resolveVersionID(
                client: client, appID: appId, versionString: version)
            let localizations: APIListResponse<VersionLocalization> = try await client.getList(
                "appStoreVersions/\(versionID)/appStoreVersionLocalizations",
                queryItems: [
                    URLQueryItem(name: "fields[appStoreVersionLocalizations]", value: "locale")
                ])
            var localizationIDs: [String: String] = [:]
            for localization in localizations.data {
                if let locale = localization.attributes?.locale {
                    localizationIDs[locale] = localization.id
                }
            }

            var pushed: [String] = []
            var created: [String] = []
            for payload in payloads {
                func value(_ attribute: MetadataAttribute) -> String? {
                    payload.values.first { $0.attribute == attribute }?.value
                }
                if let localizationID = localizationIDs[payload.locale] {
                    if dryRun {
                        output.info("[DRY RUN] Would push \(payload.locale)")
                    } else {
                        let _: APIResponse<VersionLocalization> = try await client.patch(
                            "appStoreVersionLocalizations/\(localizationID)",
                            body: LocalizationUpdateRequest(
                                data: LocalizationUpdateData(
                                    type: "appStoreVersionLocalizations", id: localizationID,
                                    attributes: LocalizationUpdateAttributes(
                                        description: value(.description),
                                        keywords: value(.keywords),
                                        whatsNew: value(.whatsNew),
                                        promotionalText: value(.promotionalText),
                                        marketingUrl: value(.marketingUrl),
                                        supportUrl: value(.supportUrl)))))
                        output.success("Pushed \(payload.locale)")
                    }
                    pushed.append(payload.locale)
                } else {
                    output.info("Creating localization: \(payload.locale)")
                    created.append(payload.locale)
                    if !dryRun {
                        let _: APIResponse<VersionLocalization> = try await client.post(
                            "appStoreVersionLocalizations",
                            body: LocalizationCreateRequest(
                                data: LocalizationCreateData(
                                    type: "appStoreVersionLocalizations",
                                    attributes: LocalizationCreateAttributes(
                                        locale: payload.locale,
                                        description: value(.description),
                                        keywords: value(.keywords),
                                        whatsNew: value(.whatsNew),
                                        promotionalText: value(.promotionalText),
                                        marketingUrl: value(.marketingUrl),
                                        supportUrl: value(.supportUrl)),
                                    relationships: LocalizationCreateRelationships(
                                        appStoreVersion: RelationshipRef(
                                            data: TypeIDRef(
                                                type: "appStoreVersions", id: versionID))))))
                        output.success("Created \(payload.locale)")
                    }
                }
            }
            if dryRun {
                output.info("[DRY RUN] \(payloads.count) locale(s) would be pushed.")
            }
            return Summary(pushed: pushed, created: created, ignored: ignored)
        }

        /// Reads every locale directory up front, enforcing character limits and the
        /// subset policy, so validation failures happen before any network traffic.
        static func scan(directory: URL) throws -> (payloads: [LocalePayload], ignored: [String]) {
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw AppctlError.fileNotFound(path: directory.path)
            }
            var payloads: [LocalePayload] = []
            var ignored: [String] = []
            let known = Dictionary(
                uniqueKeysWithValues: MetadataCommand.fileMap.map { ($0.fileName, $0.attribute) })
            for entry in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
                let localeDir = directory.appendingPathComponent(entry)
                var entryIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: localeDir.path, isDirectory: &entryIsDirectory),
                    entryIsDirectory.boolValue
                else {
                    ignored.append(entry)
                    continue
                }
                var values: [(attribute: MetadataAttribute, value: String)] = []
                for file in try fm.contentsOfDirectory(atPath: localeDir.path).sorted() {
                    guard let attribute = known[file] else {
                        ignored.append("\(entry)/\(file)")
                        continue
                    }
                    let fileURL = localeDir.appendingPathComponent(file)
                    guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                        throw AppctlError.fileNotReadable(path: fileURL.path)
                    }
                    // Inverse of pull: strip exactly the one newline pull appended.
                    let value = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
                    if let limit = attribute.characterLimit, value.count > limit.limit {
                        throw AppctlError.charLimitExceeded(
                            field: "\(entry)/\(file) (\(limit.field))",
                            limit: limit.limit, actual: value.count)
                    }
                    if !value.isEmpty { values.append((attribute, value)) }
                }
                if values.isEmpty {
                    // Subset policy: a locale directory with nothing pushable is
                    // still reported, never silently skipped.
                    ignored.append("\(entry)/ (no metadata files)")
                    continue
                }
                payloads.append(LocalePayload(locale: entry, values: values))
            }
            return (payloads, ignored)
        }
    }
}

extension MetadataCommand.MetadataAttribute: Equatable {}
