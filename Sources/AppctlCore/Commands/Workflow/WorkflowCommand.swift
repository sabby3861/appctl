import ArgumentParser
import Foundation

public struct WorkflowCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "workflow", abstract: "Automated multi-step workflows.",
        subcommands: [Release.self, Publish.self, Watch.self, Diff.self])
    public init() {}

    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Full release: find build → create version → attach → submit.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Version string.") var version: String
        @Option(name: .long, help: "Build ID (default: latest valid).") var buildId: String?
        @Option(name: .long, help: "Platform.") var platform: String = "IOS"
        @Option(name: .long, help: "Release type.") var releaseType: String = "AFTER_APPROVAL"
        @Flag(name: .long, help: "Enable phased rollout.") var phased = false
        @Flag(name: .long, help: "Preview without changes.") var dryRun = false
        @Flag(name: .long, help: "Skip review submission.") var skipSubmit = false
        @Flag(name: .long, help: .hidden) var legacySubmit = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let id = try resolveAppID(appId, config: config)
            try await Self.execute(
                client: client, output: output, appId: id, version: version, buildId: buildId,
                platform: platform, releaseType: releaseType, phased: phased, dryRun: dryRun,
                skipSubmit: skipSubmit, legacySubmit: legacySubmit)
        }

        struct ResolvedBuild: Sendable {
            let id: String
            let displayVersion: String
            let processingState: String?
        }

        /// `--build-id` takes a `builds` resource id, not a build number: the id feeds the
        /// version→build relationship while the fetched `attributes.version` is what humans
        /// see. Fetching up front also fails fast on a typo, before the pipeline mutates
        /// anything. A 404 is remapped to `resourceNotFound` because a raw API 404
        /// deliberately carries no Fix hint, and this one has an obvious fix.
        static func resolveExplicitBuild(
            client: any AppStoreConnectClient, buildId: String
        ) async throws -> ResolvedBuild {
            let response: APIResponse<Build>
            do {
                response = try await client.get("builds/\(buildId)")
            } catch AppctlError.apiError(_, let statusCode, _) where statusCode == 404 {
                throw AppctlError.resourceNotFound(type: "Build", identifier: buildId)
            } catch AppctlError.requestFailed(_, let statusCode, _) where statusCode == 404 {
                throw AppctlError.resourceNotFound(type: "Build", identifier: buildId)
            }
            return ResolvedBuild(
                id: buildId,
                displayVersion: response.data.attributes?.version ?? buildId,
                processingState: response.data.attributes?.processingState)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, appId id: String,
            version: String, buildId: String?, platform: String, releaseType: String,
            phased: Bool, dryRun: Bool, skipSubmit: Bool, legacySubmit: Bool
        ) async throws {
            output.info("Starting release pipeline for \(version)")
            // Step 1: Resolve build
            let resolvedBuildId: String
            let buildVersion: String
            if let explicit = buildId {
                let s = output.startSpinner("Validating build \(explicit)")
                let resolved: ResolvedBuild
                do {
                    resolved = try await resolveExplicitBuild(client: client, buildId: explicit)
                } catch {
                    s.stop(success: false)
                    throw error
                }
                s.stop()
                resolvedBuildId = resolved.id
                buildVersion = resolved.displayVersion
                output.success("Found build \(buildVersion)")
                if let state = resolved.processingState, state != "VALID" {
                    output.warning("Build \(buildVersion) processing state is \(state) — attach may fail.")
                }
            } else {
                let s = output.startSpinner("Finding latest valid build")
                let builds: APIListResponse<Build> = try await client.getList(
                    "builds",
                    queryItems: [
                        URLQueryItem(name: "filter[app]", value: id),
                        URLQueryItem(name: "filter[processingState]", value: "VALID"),
                        URLQueryItem(name: "filter[expired]", value: "false"),
                        URLQueryItem(name: "sort", value: "-uploadedDate"),
                    ], limit: 1, pageSize: 1)
                guard let latest = builds.data.first else {
                    s.stop(success: false)
                    throw AppctlError.resourceNotFound(
                        type: "Build",
                        identifier: "no VALID, non-expired build for app \(id)"
                    )
                }
                s.stop()
                resolvedBuildId = latest.id
                buildVersion = latest.attributes?.version ?? latest.id
                output.success("Found build \(buildVersion)")
                if latest.attributes?.usesNonExemptEncryption == nil && !dryRun {
                    let _: APIResponse<Build> = try await client.patch(
                        "builds/\(resolvedBuildId)",
                        body: ComplianceUpdateRequest(
                            data: ComplianceUpdateData(
                                type: "builds", id: resolvedBuildId,
                                attributes: ComplianceUpdateAttributes(usesNonExemptEncryption: false))))
                    output.success("Compliance set to exempt")
                }
            }
            if dryRun {
                output.info(
                    "[DRY RUN] 1.Create \(version) 2.Attach build \(buildVersion) \(phased ? "3.Phased release " : "")\(!skipSubmit ? "\(phased ? "4" : "3").Submit" : "")"
                )
                return
            }
            // Step 2: Create version
            let vs = output.startSpinner("Creating version \(version)")
            let vr: APIResponse<AppStoreVersion> = try await client.post(
                "appStoreVersions",
                body: VersionCreateRequest(
                    data: VersionCreateData(
                        type: "appStoreVersions",
                        attributes: VersionCreateAttributes(
                            platform: platform.uppercased(), versionString: version,
                            releaseType: releaseType.uppercased()),
                        relationships: VersionCreateRelationships(
                            app: RelationshipRef(data: TypeIDRef(type: "apps", id: id))))))
            vs.stop()
            output.success("Version \(version) created")
            // Step 3: Attach build
            let as2 = output.startSpinner("Attaching build")
            try await client.patchVoid(
                "appStoreVersions/\(vr.data.id)/relationships/build",
                body: BuildAttachRequest(data: TypeIDRef(type: "builds", id: resolvedBuildId))
            )
            as2.stop()
            output.success("Build attached")
            // Step 4: Submit
            if !skipSubmit {
                if legacySubmit { printLegacySubmitDeprecationWarning() }
                let ss = output.startSpinner("Submitting for review")
                do {
                    if legacySubmit {
                        let _: APIResponse<SubmissionResponse> = try await client.post(
                            "appStoreVersionSubmissions",
                            body: SubmissionCreateRequest(
                                data: SubmissionCreateData(
                                    type: "appStoreVersionSubmissions",
                                    relationships: SubmissionRelationships(
                                        appStoreVersion: RelationshipRef(
                                            data: TypeIDRef(type: "appStoreVersions", id: vr.data.id))))))
                    } else {
                        try await ReviewSubmissionService(client: client).submit(
                            appId: id, platform: platform.uppercased(), versionId: vr.data.id)
                    }
                    ss.stop()
                    output.success("Submitted for review!")
                } catch {
                    ss.stop(success: false)
                    output.error(
                        "Submission failed. Version \(version) was created and the build attached — fix the issue below, then run `appctl versions submit \(vr.data.id)`."
                    )
                    throw error
                }
            }
            output.success("Release pipeline complete for \(version)")
        }
    }

    struct Publish: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Publish latest build to TestFlight.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Beta Group ID.") var groupId: String?
        @Flag(name: .long, help: "Auto-select internal group.") var `internal` = false
        @Flag(name: .long, help: "Auto-select external group.") var external = false
        @Flag(name: .long, help: "Preview.") var dryRun = false
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let id = try resolveAppID(appId, config: config)
            let s = output.startSpinner("Finding latest build")
            let builds: APIListResponse<Build> = try await client.getList(
                "builds",
                queryItems: [
                    URLQueryItem(name: "filter[app]", value: id),
                    URLQueryItem(name: "filter[processingState]", value: "VALID"),
                    URLQueryItem(name: "filter[expired]", value: "false"),
                    URLQueryItem(name: "sort", value: "-uploadedDate"),
                ], limit: 1, pageSize: 1)
            guard let build = builds.data.first else {
                s.stop(success: false)
                throw AppctlError.resourceNotFound(
                    type: "Build",
                    identifier: "no VALID, non-expired build for app \(id)"
                )
            }
            s.stop()
            output.success("Found build \(build.attributes?.version ?? build.id)")
            if build.attributes?.usesNonExemptEncryption == nil && !dryRun {
                let _: APIResponse<Build> = try await client.patch(
                    "builds/\(build.id)",
                    body: ComplianceUpdateRequest(
                        data: ComplianceUpdateData(
                            type: "builds", id: build.id,
                            attributes: ComplianceUpdateAttributes(usesNonExemptEncryption: false))))
                output.success("Compliance set")
            }
            let targetGroupId: String
            if let g = groupId {
                targetGroupId = g
            } else {
                let gs = output.startSpinner("Finding groups")
                let groups: APIListResponse<BetaGroup> = try await client.getList(
                    "betaGroups",
                    queryItems: [URLQueryItem(name: "filter[app]", value: id)]
                )
                gs.stop()
                if groups.data.isEmpty {
                    throw AppctlError.resourceNotFound(type: "BetaGroup", identifier: "app \(id)")
                }
                if `internal` {
                    guard let g = groups.data.first(where: { $0.attributes?.isInternalGroup == true }) else {
                        throw AppctlError.resourceNotFound(
                            type: "BetaGroup",
                            identifier: "no internal group for app \(id)"
                        )
                    }
                    targetGroupId = g.id
                } else if external {
                    guard let g = groups.data.first(where: { $0.attributes?.isInternalGroup != true }) else {
                        throw AppctlError.resourceNotFound(
                            type: "BetaGroup",
                            identifier: "no external group for app \(id)"
                        )
                    }
                    targetGroupId = g.id
                } else {
                    for g in groups.data {
                        let kind = g.attributes?.isInternalGroup == true ? "internal" : "external"
                        output.info("  \(g.id.truncated(to: 12))  \(g.attributes?.name ?? "—")  (\(kind))")
                    }
                    throw AppctlError.missingRequiredField(
                        field: "group-id",
                        in: "command arguments (or use --internal/--external to auto-select)"
                    )
                }
            }
            if dryRun {
                output.info("[DRY RUN] Would distribute to group \(targetGroupId)")
                return
            }
            let ds = output.startSpinner("Distributing to TestFlight")
            try await client.postVoid(
                "betaGroups/\(targetGroupId)/relationships/builds",
                body: BuildGroupAssignmentBody(data: [TypeIDRef(type: "builds", id: build.id)]))
            ds.stop()
            output.success("Build distributed to TestFlight!")
        }
    }

    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Watch for build/review status changes.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Poll interval (seconds).") var interval: Int = 30
        @Option(name: .long, help: "Max duration (minutes).") var timeout: Int = 120
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            try Self.validate(interval: interval, timeout: timeout)

            let (client, config) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let id = try resolveAppID(appId, config: config)
            output.info("Watching app \(id) (Ctrl+C to stop)")

            var lastBuild: [String: String] = [:]
            var lastVersion: [String: String] = [:]
            var consecutiveFailures = 0
            let maxConsecutiveFailures = 3
            let totalIterations = (timeout * 60) / interval

            for _ in 0..<totalIterations {
                do {
                    let builds: APIListResponse<Build> = try await client.getList(
                        "builds",
                        queryItems: [
                            URLQueryItem(name: "filter[app]", value: id),
                            URLQueryItem(name: "sort", value: "-uploadedDate"),
                        ], limit: 3, pageSize: 3
                    )
                    for b in builds.data {
                        let st = b.attributes?.processingState ?? ""
                        if let prev = lastBuild[b.id], prev != st {
                            output.success(
                                "Build \(b.attributes?.version ?? b.id): \(prev) → \(st.processingStateDisplay)")
                        }
                        lastBuild[b.id] = st
                    }

                    let vers: APIListResponse<AppStoreVersion> = try await client.getList(
                        "apps/\(id)/appStoreVersions", limit: 2, pageSize: 2
                    )
                    for v in vers.data {
                        let st = v.attributes?.appStoreState ?? ""
                        if let prev = lastVersion[v.id], prev != st {
                            output.success("Version \(v.attributes?.versionString ?? v.id): \(st.versionStateDisplay)")
                            if st == "READY_FOR_SALE" {
                                output.success("🎉 App is LIVE!")
                                return
                            }
                        }
                        lastVersion[v.id] = st
                    }

                    consecutiveFailures = 0
                } catch is CancellationError {
                    throw AppctlError.operationCancelled
                } catch {
                    consecutiveFailures += 1
                    output.warning(
                        "Poll failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(error.localizedDescription)")
                    if consecutiveFailures >= maxConsecutiveFailures {
                        throw error
                    }
                }
                try await Task.sleep(for: .seconds(interval))
            }
            output.warning("Watch timed out after \(timeout)m")
        }

        /// Validate before any I/O. The cap on `timeout` prevents `timeout * 60`
        /// further down from overflowing.
        static func validate(interval: Int, timeout: Int) throws {
            guard interval > 0 else {
                throw AppctlError.invalidInput(
                    field: "--interval",
                    value: String(interval),
                    expected: "A positive number of seconds"
                )
            }
            guard (1...1440).contains(timeout) else {
                throw AppctlError.invalidInput(
                    field: "--timeout",
                    value: String(timeout),
                    expected: "1 to 1440 minutes (24 hours)"
                )
            }
        }
    }

    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Compare two builds.")
        @Argument(help: "First build ID.") var buildA: String
        @Argument(help: "Second build ID.") var buildB: String
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, _) = try globals.apiClient()
            let output = OutputFormatter(format: globals.resolvedFormat, noColor: globals.noColor)
            let spinner = output.startSpinner("Fetching builds")
            let rA: APIResponse<Build> = try await client.get("builds/\(buildA)")
            let rB: APIResponse<Build> = try await client.get("builds/\(buildB)")
            spinner.stop()
            let a = rA.data.attributes
            let b = rB.data.attributes
            output.printDetail(fields: [
                ("Build:", "\(a?.version ?? "?") → \(b?.version ?? "?")"),
                ("Min OS:", "\(a?.minOsVersion ?? "?") → \(b?.minOsVersion ?? "?")"),
                ("State:", "\(a?.processingState ?? "?") → \(b?.processingState ?? "?")"),
                ("Uploaded A:", a?.uploadedDate?.formattedDate() ?? "—"),
                ("Uploaded B:", b?.uploadedDate?.formattedDate() ?? "—"),
            ])
        }
    }
}
