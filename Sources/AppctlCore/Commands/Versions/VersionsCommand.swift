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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let id = try resolveAppID(appId, config: config)
            let spinner = output.startSpinner("Fetching versions")
            var q: [URLQueryItem] = [
                URLQueryItem(
                    name: "fields[appStoreVersions]",
                    value: "platform,versionString,appStoreState,releaseType,createdDate"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            if let p = platform { q.append(URLQueryItem(name: "filter[platform]", value: p.uppercased())) }
            do {
                let r: APIListResponse<AppStoreVersion> = try await client.getList(
                    "apps/\(id)/appStoreVersions", queryItems: q)
                spinner.stop()
                output.printList(
                    r.data,
                    columns: [
                        Column(header: "ID") { $0.id.truncated(to: 12) },
                        Column(header: "Version") { $0.attributes?.versionString ?? "—" },
                        Column(header: "State") { $0.attributes?.appStoreState?.versionStateDisplay ?? "—" },
                        Column(header: "Created") { $0.attributes?.createdDate?.formattedDate() ?? "—" },
                    ])
            } catch {
                spinner.stop(success: false)
                throw error
            }
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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let id = try resolveAppID(appId, config: config)
            if dryRun {
                output.info("[DRY RUN] Would create version \(version) for app \(id)")
                return
            }
            let spinner = output.startSpinner("Creating version \(version)")
            let body = VersionCreateRequest(
                data: VersionCreateData(
                    type: "appStoreVersions",
                    attributes: VersionCreateAttributes(
                        platform: platform.uppercased(), versionString: version, releaseType: releaseType.uppercased()),
                    relationships: VersionCreateRelationships(
                        app: RelationshipRef(data: TypeIDRef(type: "apps", id: id)))))
            do {
                let r: APIResponse<AppStoreVersion> = try await client.post("appStoreVersions", body: body)
                spinner.stop()
                output.success("Created version \(version) (ID: \(r.data.id))")
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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            if dryRun {
                output.info("[DRY RUN] Would update version \(versionId)")
                return
            }
            if let b = buildId {
                let s = output.startSpinner("Attaching build \(b)")
                do {
                    try await client.patchVoid(
                        "appStoreVersions/\(versionId)/relationships/build",
                        body: BuildAttachRequest(data: TypeIDRef(type: "builds", id: b))
                    )
                    s.stop()
                    output.success("Build attached")
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
                    let _: APIResponse<AppStoreVersion> = try await client.patch(
                        "appStoreVersions/\(versionId)", body: body)
                    s.stop()
                    output.success("Version updated")
                } catch {
                    s.stop(success: false)
                    throw error
                }
            }
        }
    }

    struct Submit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Submit version for App Store review.")
        @Argument(help: "Version ID.") var versionId: String
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            if dryRun {
                output.info("[DRY RUN] Would submit version \(versionId) for review")
                return
            }
            let spinner = output.startSpinner("Submitting for review")
            let body = SubmissionCreateRequest(
                data: SubmissionCreateData(
                    type: "appStoreVersionSubmissions",
                    relationships: SubmissionRelationships(
                        appStoreVersion: RelationshipRef(data: TypeIDRef(type: "appStoreVersions", id: versionId)))))
            do {
                let _: APIResponse<SubmissionResponse> = try await client.post("appStoreVersionSubmissions", body: body)
                spinner.stop()
                output.success("Submitted for review!")
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

            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
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
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            if dryRun {
                output.info("[DRY RUN] Would reject version \(versionId)")
                return
            }
            let spinner = output.startSpinner("Removing from review")
            do {
                // The DELETE endpoint takes a submission ID, not a version ID, so we have to
                // resolve the version's current submission first.
                let response: OptionalAPIResponse<SubmissionResponse> = try await client.get(
                    "appStoreVersions/\(versionId)/appStoreVersionSubmission"
                )
                guard let submission = response.data else {
                    throw AppctlError.resourceNotFound(
                        type: "Submission",
                        identifier: "version \(versionId) is not currently submitted for review"
                    )
                }
                try await client.delete("appStoreVersionSubmissions/\(submission.id)")
                spinner.stop()
                output.success("Version developer-rejected")
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
