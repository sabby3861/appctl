import ArgumentParser
import Foundation

public struct VersionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "versions", abstract: "Manage App Store versions.",
        subcommands: [List.self, Create.self, Update.self, Submit.self, PhasedRelease.self, Reject.self],
        defaultSubcommand: List.self)
    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List App Store versions.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Filter by platform.") var platform: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            let spinner = output.startSpinner("Fetching versions")
            do {
                let (versions, next) = try await Self.execute(
                    client: client, appId: id, platform: platform,
                    nextActions: globals.nextActions())
                spinner.stop()
                output.printList(
                    versions,
                    columns: [
                        Column(header: "ID", value: { $0.id.truncated(to: 12) }, jsonValue: { $0.id }),
                        Column(header: "Version") { $0.attributes?.versionString ?? "—" },
                        Column(
                            header: "State",
                            value: { $0.attributes?.appStoreState?.versionStateDisplay ?? "—" },
                            jsonValue: { $0.attributes?.appStoreState ?? "" }),
                        Column(header: "Created") { $0.attributes?.createdDate?.formattedDate() ?? "—" },
                    ],
                    next: next.isEmpty ? nil : next)
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }

        static func execute(
            client: any AppStoreConnectClient, appId: String, platform: String?,
            nextActions: NextActions
        ) async throws -> (versions: [AppStoreVersion], next: [String: String]) {
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[appStoreVersions]",
                    value: "platform,versionString,appStoreState,releaseType,createdDate")
            ]
            if let p = platform { q.append(URLQueryItem(name: "filter[platform]", value: p.uppercased())) }
            let r: APIListResponse<AppStoreVersion> = try await client.getList(
                "apps/\(appId)/appStoreVersions", queryItems: q, limit: 10, pageSize: 10)
            let next = nextActions.forVersions(r.data.map { ($0.id, $0.attributes?.appStoreState) })
            return (r.data, next)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new App Store version.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Version string.") var version: String
        @Option(name: .long, help: "Platform.") var platform: String = "IOS"
        @Option(name: .long, help: "Release type.") var releaseType: String = "AFTER_APPROVAL"
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            if let outcome = try await Self.execute(
                client: client, output: output, appId: id, version: version,
                platform: platform, releaseType: releaseType, dryRun: dryRun,
                nextActions: globals.nextActions())
            {
                output.printMutation(outcome)
            }
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId: String,
            version: String, platform: String, releaseType: String, dryRun: Bool,
            nextActions: NextActions
        ) async throws -> MutationOutcome? {
            if dryRun {
                output.info("[DRY RUN] Would create version \(version) for app \(appId)")
                return nil
            }
            let spinner = output.startSpinner("Creating version \(version)")
            let body = VersionCreateRequest(
                data: VersionCreateData(
                    type: "appStoreVersions",
                    attributes: VersionCreateAttributes(
                        platform: platform.uppercased(), versionString: version, releaseType: releaseType.uppercased()),
                    relationships: VersionCreateRelationships(
                        app: RelationshipRef(data: TypeIDRef(type: "apps", id: appId)))))
            do {
                let r: APIResponse<AppStoreVersion> = try await client.post("appStoreVersions", body: body)
                spinner.stop()
                output.success("Created version \(version) (ID: \(r.data.id))")
                let state = r.data.attributes?.appStoreState
                let next = nextActions.forVersions([(r.data.id, state)])
                return MutationOutcome(
                    data: .object([
                        "id": .string(r.data.id),
                        "version": .string(r.data.attributes?.versionString ?? version),
                        "platform": .string(r.data.attributes?.platform ?? platform.uppercased()),
                        "state": state.map(JSONValue.string) ?? .null,
                    ]),
                    next: next.isEmpty ? nil : next)
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update a version (attach build, change release type).")
        @Argument(help: "Version ID.") var versionId: String
        @Option(name: .long, help: "Build ID to attach.") var buildId: String?
        @Option(name: .long, help: "New version string.") var version: String?
        @Option(name: .long, help: "Release type.") var releaseType: String?
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            if let outcome = try await Self.execute(
                client: client, output: output, versionId: versionId,
                buildId: buildId, version: version, releaseType: releaseType, dryRun: dryRun)
            {
                output.printMutation(outcome)
            }
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, versionId: String,
            buildId: String?, version: String?, releaseType: String?, dryRun: Bool
        ) async throws -> MutationOutcome? {
            if dryRun {
                output.info("[DRY RUN] Would update version \(versionId)")
                return nil
            }
            var data: [String: JSONValue] = ["id": .string(versionId)]
            if let b = buildId {
                let s = output.startSpinner("Attaching build \(b)")
                do {
                    try await client.patchVoid(
                        "appStoreVersions/\(versionId)/relationships/build",
                        body: BuildAttachRequest(data: TypeIDRef(type: "builds", id: b))
                    )
                    s.stop()
                    output.success("Build attached")
                    data["attached_build_id"] = .string(b)
                } catch {
                    s.stop(success: false)
                    throw error
                }
            }
            if version != nil || releaseType != nil {
                let s = output.startSpinner("Updating version")
                let body = VersionUpdateRequest(
                    data: VersionUpdateData(
                        type: "appStoreVersions", id: versionId,
                        attributes: VersionUpdateAttributes(
                            versionString: version, releaseType: releaseType?.uppercased())))
                do {
                    let r: APIResponse<AppStoreVersion> = try await client.patch(
                        "appStoreVersions/\(versionId)", body: body)
                    s.stop()
                    output.success("Version updated")
                    if let v = r.data.attributes?.versionString { data["version"] = .string(v) }
                    if let rt = r.data.attributes?.releaseType { data["release_type"] = .string(rt) }
                    if let st = r.data.attributes?.appStoreState { data["state"] = .string(st) }
                } catch {
                    s.stop(success: false)
                    throw error
                }
            }
            return MutationOutcome(data: .object(data))
        }
    }

    struct Submit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Submit version for App Store review.")
        @Argument(help: "Version ID.") var versionId: String
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @Flag(name: .long, help: .hidden) var legacySubmit = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            if let outcome = try await Self.execute(
                client: client, output: output, versionId: versionId,
                dryRun: dryRun, legacySubmit: legacySubmit, nextActions: globals.nextActions())
            {
                output.printMutation(outcome)
            }
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, versionId: String,
            dryRun: Bool, legacySubmit: Bool, nextActions: NextActions
        ) async throws -> MutationOutcome? {
            if dryRun {
                output.info("[DRY RUN] Would submit version \(versionId) for review")
                return nil
            }
            if legacySubmit {
                printLegacySubmitDeprecationWarning()
                let spinner = output.startSpinner("Submitting for review (legacy)")
                let body = SubmissionCreateRequest(
                    data: SubmissionCreateData(
                        type: "appStoreVersionSubmissions",
                        relationships: SubmissionRelationships(
                            appStoreVersion: RelationshipRef(
                                data: TypeIDRef(type: "appStoreVersions", id: versionId)))))
                do {
                    let r: APIResponse<SubmissionResponse> = try await client.post(
                        "appStoreVersionSubmissions", body: body)
                    spinner.stop()
                    output.success("Submitted for review!")
                    return MutationOutcome(
                        data: .object([
                            "version_id": .string(versionId),
                            "submission_id": .string(r.data.id),
                        ]),
                        next: ["reject": nextActions.command(["versions", "reject", versionId])])
                } catch {
                    spinner.stop(success: false)
                    throw error
                }
            }
            let spinner = output.startSpinner("Submitting for review")
            do {
                let (appId, platform) = try await ReviewSubmissionService.resolveAppAndPlatform(
                    versionId: versionId, client: client)
                let result = try await ReviewSubmissionService(client: client)
                    .submit(appId: appId, platform: platform, versionId: versionId)
                spinner.stop()
                output.success(
                    result.reused
                        ? "Added to existing review submission and submitted!"
                        : "Submitted for review!")
                return MutationOutcome(
                    data: .object([
                        "version_id": .string(versionId),
                        "submission_id": .string(result.submission.id),
                        "submission_state": result.submission.attributes?.state.map(JSONValue.string)
                            ?? .null,
                        "reused": .bool(result.reused),
                    ]),
                    next: ["reject": nextActions.command(["versions", "reject", versionId])])
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct PhasedRelease: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "phased-release",
            abstract: "Manage phased release (pause/resume/complete)."
        )
        @Argument(help: "Version ID.") var versionId: String
        @Option(name: .long, help: "Action: pause, resume, complete.") var action: String
        @OptionGroup var globals: GlobalOptions
        init() {}

        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let outcome = try await Self.execute(
                client: client, output: output, versionId: versionId, action: action)
            output.printMutation(outcome)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, versionId: String,
            action: String
        ) async throws -> MutationOutcome {
            let state: String
            switch action.lowercased() {
            case "pause": state = "PAUSED"
            case "resume": state = "ACTIVE"
            case "complete": state = "COMPLETE"
            default:
                throw AppctlError.invalidInput(
                    field: "--action",
                    value: action,
                    expected: "pause, resume, or complete"
                )
            }

            let spinner = output.startSpinner("\(action.capitalized) phased release")
            do {
                // App Store Connect's PATCH endpoint takes the phased-release resource ID,
                // not the version ID. Resolve the version's current phased release first.
                let lookup: OptionalAPIResponse<PhasedReleaseResponse> = try await client.get(
                    "appStoreVersions/\(versionId)/appStoreVersionPhasedRelease"
                )
                guard let phased = lookup.data else {
                    throw AppctlError.resourceNotFound(
                        type: "PhasedRelease",
                        identifier: "version \(versionId) does not have phased release enabled"
                    )
                }
                let body = PhasedReleaseUpdateRequest(
                    data: PhasedReleaseUpdateData(
                        type: "appStoreVersionPhasedReleases",
                        id: phased.id,
                        attributes: PhasedReleaseAttributes(phasedReleaseState: state)
                    )
                )
                let _: APIResponse<PhasedReleaseResponse> = try await client.patch(
                    "appStoreVersionPhasedReleases/\(phased.id)",
                    body: body
                )
                spinner.stop()
                output.success("Phased release \(action)d")
                return MutationOutcome(
                    data: .object([
                        "id": .string(phased.id),
                        "version_id": .string(versionId),
                        "state": .string(state),
                    ]))
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove version from review (developer reject).")
        @Argument(help: "Version ID.") var versionId: String
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = try globals.outputFormatter()
            if let outcome = try await Self.execute(
                client: client, output: output, versionId: versionId, dryRun: dryRun)
            {
                output.printMutation(outcome)
            }
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, versionId: String,
            dryRun: Bool
        ) async throws -> MutationOutcome? {
            if dryRun {
                output.info("[DRY RUN] Would reject version \(versionId)")
                return nil
            }
            let spinner = output.startSpinner("Removing from review")
            do {
                // Cancellation targets the app's open review submission, not the version,
                // so resolve the version's app and platform first.
                let (appId, platform) = try await ReviewSubmissionService.resolveAppAndPlatform(
                    versionId: versionId, client: client)
                let canceled = try await ReviewSubmissionService(client: client)
                    .cancel(appId: appId, platform: platform)
                spinner.stop()
                output.success("Review submission canceled")
                return MutationOutcome(
                    data: .object([
                        "version_id": .string(versionId),
                        "submission_id": .string(canceled.id),
                        "submission_state": canceled.attributes?.state.map(JSONValue.string) ?? .null,
                    ]))
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
