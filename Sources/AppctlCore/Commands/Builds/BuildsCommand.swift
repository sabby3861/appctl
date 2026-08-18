import ArgumentParser
import Foundation

public struct BuildsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "builds", abstract: "List and manage builds.",
        subcommands: [List.self, Info.self, SetCompliance.self, Upload.self], defaultSubcommand: List.self)
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
            let output = try globals.outputFormatter()
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
            let output = try globals.outputFormatter()
            try await Self.execute(client: client, output: output, buildId: buildId)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, buildId: String
        ) async throws {
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

    struct Upload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Upload an .ipa/.pkg to App Store Connect.",
            discussion: """
                The default backend uses the Build Upload API and is resumable: completed
                parts are recorded in a sidecar file next to the archive, so re-running
                after an interruption uploads only the missing parts.
                """)
        @Option(name: .long, help: "Path to the .ipa or .pkg to upload.") var file: String
        @Option(name: .long, help: "App ID.") var appId: String?
        @Option(name: .long, help: "Platform: ios, macos, tvos, visionos.") var platform = "ios"
        @Option(name: .long, help: "Upload backend: api or altool.") var backend = "api"
        @Flag(name: .long, help: "Wait for build processing and reflect the result in the exit code.")
        var wait = false
        @Flag(name: .long, help: "Preview the upload without sending anything.") var dryRun = false
        @Option(name: .long, help: "CFBundleShortVersionString override (parsed from the IPA when omitted).")
        var shortVersion: String?
        @Option(name: .long, help: "CFBundleVersion override (parsed from the IPA when omitted).")
        var bundleVersion: String?
        @Option(
            name: .long, help: "CFBundleIdentifier override, altool backend only (parsed from the IPA when omitted).")
        var bundleId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}

        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let appID = try resolveAppID(appId, config: config)
            guard Self.ascPlatform(for: platform) != nil else {
                throw AppctlError.invalidInput(
                    field: "platform", value: platform, expected: "ios, macos, tvos, or visionos")
            }
            let archive = URL(filePath: NSString(string: file).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                throw AppctlError.fileNotFound(path: archive.path)
            }
            let metadata = try resolveMetadata(archive: archive)
            let outcome: MutationOutcome?
            switch backend {
            case "api":
                outcome = try await Self.executeAPI(
                    client: client, output: output, archive: archive, appID: appID,
                    platform: platform, shortVersion: metadata.shortVersion,
                    bundleVersion: metadata.bundleVersion, wait: wait, dryRun: dryRun)
            case "altool":
                outcome = try await Self.executeAltool(
                    client: client, output: output, config: config, archive: archive,
                    appID: appID, platform: platform, metadata: metadata,
                    wait: wait, dryRun: dryRun, runner: SubprocessRunner())
            default:
                throw AppctlError.invalidInput(field: "backend", value: backend, expected: "api or altool")
            }
            if let outcome { output.printMutation(outcome) }
        }

        /// Flags win over IPA parsing; parsing only runs for values not supplied.
        /// A .pkg (no Payload/*.app) therefore works when all three flags are given.
        private func resolveMetadata(archive: URL) throws -> ArchiveMetadata {
            if let shortVersion, let bundleVersion, backend != "altool" || bundleId != nil {
                return ArchiveMetadata(
                    bundleID: bundleId ?? "", shortVersion: shortVersion, bundleVersion: bundleVersion)
            }
            let parsed = try IPAInspector.inspect(ipaAt: archive)
            return ArchiveMetadata(
                bundleID: bundleId ?? parsed.bundleID,
                shortVersion: shortVersion ?? parsed.shortVersion,
                bundleVersion: bundleVersion ?? parsed.bundleVersion)
        }

        static func ascPlatform(for platform: String) -> String? {
            switch platform.lowercased() {
            case "ios": return "IOS"
            case "macos": return "MAC_OS"
            case "tvos": return "TV_OS"
            case "visionos": return "VISION_OS"
            default: return nil
            }
        }

        static func uti(for archive: URL) -> String {
            archive.pathExtension.lowercased() == "pkg" ? "com.apple.pkg" : "com.apple.ipa"
        }

        static func executeAPI(
            client: any AppStoreConnectClient, output: OutputFormatter, archive: URL,
            appID: String, platform: String, shortVersion: String, bundleVersion: String,
            wait: Bool, dryRun: Bool, retryBaseDelay: TimeInterval = 1.0,
            pollInterval: Duration = .seconds(30), maxPolls: Int = 240
        ) async throws -> MutationOutcome? {
            guard let ascPlatform = ascPlatform(for: platform) else {
                throw AppctlError.invalidInput(
                    field: "platform", value: platform, expected: "ios, macos, tvos, or visionos")
            }
            if dryRun {
                var steps = [
                    "POST v1/buildUploads (\(shortVersion) (\(bundleVersion)), \(ascPlatform), app \(appID))",
                    "POST v1/buildUploadFiles (reserve \(archive.lastPathComponent))",
                    "PUT each upload operation's byte range (resumable via \(UploadSidecar.url(for: archive).lastPathComponent))",
                    "PATCH v1/buildUploadFiles/{id} (commit: uploaded=true + MD5 checksum)",
                ]
                if wait { steps.append("Poll GET v1/builds until processing completes") }
                output.info("Dry run — no requests will be sent. Planned sequence:")
                // printDetail rather than info so the plan also reaches piped/JSON
                // consumers, where stderr decoration is suppressed.
                output.printDetail(
                    fields: steps.enumerated().map { ("\($0.offset + 1).", $0.element) })
                return nil
            }
            let service = BuildUploadService(client: client, retryBaseDelay: retryBaseDelay)
            let reporter = ProgressReporter(output: output)
            let result = try await service.upload(
                archive: archive, appID: appID, platform: ascPlatform,
                cfBundleShortVersionString: shortVersion, cfBundleVersion: bundleVersion,
                uti: uti(for: archive), progress: { reporter.report($0) })
            reporter.finish()
            if result.partsSkipped > 0 {
                output.info(
                    "Resumed: \(result.partsSkipped) part(s) were already uploaded, sent \(result.partsUploaded).")
            }
            output.success("Upload complete (buildUpload \(result.buildUploadID)). Processing has started.")
            var data: [String: JSONValue] = [
                "backend": .string("api"),
                "build_upload_id": .string(result.buildUploadID),
                "parts_uploaded": .int(result.partsUploaded),
                "parts_skipped": .int(result.partsSkipped),
            ]
            if wait {
                let processed = try await waitForProcessing(
                    client: client, output: output, appID: appID, version: bundleVersion,
                    pollInterval: pollInterval, maxPolls: maxPolls)
                data["processing_state"] = .string(processed.state)
                data["version"] = processed.version.map(JSONValue.string) ?? .null
            }
            return MutationOutcome(data: .object(data))
        }

        static func executeAltool(
            client: any AppStoreConnectClient, output: OutputFormatter, config: AppctlConfig,
            archive: URL, appID: String, platform: String, metadata: ArchiveMetadata,
            wait: Bool, dryRun: Bool, runner: any ProcessRunner,
            pollInterval: Duration = .seconds(30), maxPolls: Int = 240
        ) async throws -> MutationOutcome? {
            guard let altoolType = AltoolBackend.altoolType(forPlatform: platform) else {
                throw AppctlError.invalidInput(
                    field: "platform", value: platform, expected: "ios, macos, tvos, or visionos")
            }
            guard let keyID = config.keyID, let issuerID = config.issuerID else {
                throw AppctlError.missingAPIKey(detail: "The altool backend needs --key-id and --issuer-id.")
            }
            guard !metadata.bundleID.isEmpty else {
                throw AppctlError.missingRequiredField(
                    field: "bundle-id", in: "the archive's Info.plist or the --bundle-id flag")
            }
            let invocation = AltoolBackend.invocation(
                file: archive.path, altoolType: altoolType, appleID: appID,
                bundleID: metadata.bundleID, shortVersion: metadata.shortVersion,
                bundleVersion: metadata.bundleVersion, keyID: keyID, issuerID: issuerID)
            if dryRun {
                output.info("Dry run — would execute:")
                print(invocation.joined(separator: " "))
                return nil
            }
            guard AltoolBackend.keyFileExists(keyID: keyID) else {
                throw AppctlError.altoolKeyNotFound(keyID: keyID, searchedDirs: AltoolBackend.keySearchDirs)
            }
            try await AltoolBackend.run(invocation: invocation, runner: runner, output: output)
            output.success("altool upload complete. Processing has started.")
            var data: [String: JSONValue] = [
                "backend": .string("altool"),
                "file": .string(archive.lastPathComponent),
            ]
            if wait {
                let processed = try await waitForProcessing(
                    client: client, output: output, appID: appID, version: metadata.bundleVersion,
                    pollInterval: pollInterval, maxPolls: maxPolls)
                data["processing_state"] = .string(processed.state)
                data["version"] = processed.version.map(JSONValue.string) ?? .null
            }
            return MutationOutcome(data: .object(data))
        }

        /// Polls `GET /v1/builds` until the uploaded build reaches a terminal
        /// processing state. VALID exits 0; FAILED/INVALID throws so the process
        /// exits non-zero. `version` (CFBundleVersion) pins the exact build; without
        /// it we fall back to the newest upload, which is only a heuristic.
        static func waitForProcessing(
            client: any AppStoreConnectClient, output: OutputFormatter, appID: String,
            version: String?, pollInterval: Duration, maxPolls: Int
        ) async throws -> (state: String, version: String?) {
            if version == nil || version?.isEmpty == true {
                output.warning(
                    "Resolving build by newest upload — if multiple uploads are in flight this may watch the wrong build."
                )
            }
            var q: [URLQueryItem] = [
                URLQueryItem(name: "filter[app]", value: appID),
                URLQueryItem(name: "sort", value: "-uploadedDate"),
                URLQueryItem(name: "fields[builds]", value: "version,processingState,uploadedDate"),
            ]
            if let version, !version.isEmpty {
                q.append(URLQueryItem(name: "filter[version]", value: version))
            }
            let spinner = output.startSpinner("Waiting for build processing")
            for _ in 0..<maxPolls {
                let r: APIListResponse<Build>
                do {
                    r = try await client.getList("builds", queryItems: q, limit: 1, pageSize: 1)
                } catch {
                    spinner.stop(success: false)
                    throw error
                }
                let state = r.data.first?.attributes?.processingState?.uppercased()
                switch state {
                case "VALID":
                    spinner.stop()
                    output.success("Build \(r.data.first?.attributes?.version ?? "?") processed: VALID")
                    return (state: "VALID", version: r.data.first?.attributes?.version)
                case "FAILED", "INVALID":
                    spinner.stop(success: false)
                    throw AppctlError.buildProcessingFailed(state: state ?? "?", details: [])
                default:
                    // nil (build not visible yet) or PROCESSING — keep polling.
                    try await Task.sleep(for: pollInterval)
                }
            }
            spinner.stop(success: false)
            throw AppctlError.timeout(
                url: "v1/builds?filter[app]=\(appID)",
                duration: Double(maxPolls) * Double(pollInterval.components.seconds))
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
            let output = try globals.outputFormatter()
            let outcome = try await Self.execute(
                client: client, output: output, buildId: buildId, usesEncryption: usesEncryption)
            output.printMutation(outcome)
        }

        static func execute(
            client: any AppStoreConnectClient, output: OutputFormatter, buildId: String,
            usesEncryption: Bool
        ) async throws -> MutationOutcome {
            let spinner = output.startSpinner("Setting export compliance")
            let body = ComplianceUpdateRequest(
                data: ComplianceUpdateData(
                    type: "builds", id: buildId,
                    attributes: ComplianceUpdateAttributes(usesNonExemptEncryption: usesEncryption)))
            do {
                let r: APIResponse<Build> = try await client.patch("builds/\(buildId)", body: body)
                spinner.stop()
                output.success(
                    usesEncryption
                        ? "Compliance declared: uses non-exempt encryption"
                        : "Compliance declared: exempt (standard HTTPS only)")
                return MutationOutcome(
                    data: .object([
                        "id": .string(r.data.id),
                        "uses_non_exempt_encryption": .bool(usesEncryption),
                    ]))
            } catch {
                spinner.stop(success: false)
                throw error
            }
        }
    }
}
