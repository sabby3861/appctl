import Foundation

/// Orchestrates screenshot uploads in the fastlane directory layout
/// (`<path>/<locale>/*.png|jpg`). Validation is strictly batch-level: every file in
/// every locale is checked (format, alpha, exact pixel dimensions) before the first
/// network request, so a single bad file aborts the run with zero uploads.
///
/// Per image the flow mirrors the Build Upload API: reserve an appScreenshot
/// (creating the localization and display-type set on demand) → PUT each upload
/// operation's byte range (bounded concurrency, retry with backoff) → commit with
/// the whole-file MD5.
public struct ScreenshotUploadService: Sendable {
    private let client: any AppStoreConnectClient
    /// Base delay for per-part retry backoff; tests pass 0 to avoid sleeping.
    private let retryBaseDelay: TimeInterval
    private let maxPartAttempts = 3
    private let maxConcurrentPuts = 4

    public init(client: any AppStoreConnectClient, retryBaseDelay: TimeInterval = 1.0) {
        self.client = client
        self.retryBaseDelay = retryBaseDelay
    }

    public struct PlannedScreenshot: Sendable {
        public let locale: String
        public let file: URL
        public let displayType: String
        public let fileSize: Int64
    }

    public struct ValidationResult: Sendable {
        public let plan: [PlannedScreenshot]
        /// Relative paths (locale/file) that are not screenshot candidates —
        /// reported to the user, never silently skipped.
        public let ignored: [String]
    }

    public struct Summary: Sendable {
        public let uploadedCount: Int
        public let localizationsCreated: [String]
        public let setsCreated: Int
    }

    private static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg"]

    // MARK: - Validation (no network)

    public static func validate(directory: URL) throws -> ValidationResult {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw AppctlError.fileNotFound(path: directory.path)
        }

        var plan: [PlannedScreenshot] = []
        var ignored: [String] = []
        var failures: [String] = []
        let entries = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        for entry in entries {
            let localeURL = directory.appendingPathComponent(entry)
            var entryIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: localeURL.path, isDirectory: &entryIsDirectory),
                entryIsDirectory.boolValue
            else {
                ignored.append(entry)
                continue
            }
            let files = try fm.contentsOfDirectory(atPath: localeURL.path).sorted()
            for file in files {
                let relative = "\(entry)/\(file)"
                let fileURL = localeURL.appendingPathComponent(file)
                guard
                    screenshotExtensions.contains(fileURL.pathExtension.lowercased())
                else {
                    ignored.append(relative)
                    continue
                }
                do {
                    let info = try ImageInspector.inspect(fileURL)
                    if let failure = Self.validationFailure(for: info) {
                        failures.append("\(relative): \(failure)")
                        continue
                    }
                    guard
                        let displayType = ScreenshotDimensions.displayType(
                            width: info.width, height: info.height)
                    else {
                        failures.append(
                            "\(relative): got \(info.width)×\(info.height); not an accepted App Store size"
                        )
                        continue
                    }
                    plan.append(
                        PlannedScreenshot(
                            locale: entry, file: fileURL, displayType: displayType,
                            fileSize: try UploadFileAccess.fileSize(of: fileURL)))
                } catch let error as AppctlError {
                    failures.append("\(relative): \(Self.firstLine(of: error))")
                }
            }
        }
        guard failures.isEmpty else {
            throw AppctlError.screenshotValidationFailed(failures: failures)
        }
        guard !plan.isEmpty else {
            throw AppctlError.invalidInput(
                field: "path", value: directory.path,
                expected: "At least one screenshot in the fastlane layout <path>/<locale>/*.png|jpg")
        }
        return ValidationResult(plan: plan, ignored: ignored)
    }

    private static func validationFailure(for info: ImageInfo) -> String? {
        switch info.format {
        case .heic:
            return "HEIC is not supported by App Store Connect; export as PNG or JPEG"
        case .png where info.hasAlpha:
            return "PNG has an alpha channel; App Store screenshots cannot contain transparency"
        default:
            return nil
        }
    }

    private static func firstLine(of error: AppctlError) -> String {
        error.diagnosticMessage.split(separator: "\n").map(String.init)
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Upload

    public func upload(
        plan: [PlannedScreenshot], appID: String, versionString: String,
        dryRun: Bool, output: OutputFormatter
    ) async throws -> Summary {
        let versionID = try await AppStoreVersionResolver.resolveVersionID(
            client: client, appID: appID, versionString: versionString)

        let existing: APIListResponse<VersionLocalization> = try await client.getList(
            "appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            queryItems: [
                URLQueryItem(name: "fields[appStoreVersionLocalizations]", value: "locale")
            ])
        var localizationIDs: [String: String] = [:]
        for localization in existing.data {
            if let locale = localization.attributes?.locale {
                localizationIDs[locale] = localization.id
            }
        }

        var uploadedCount = 0
        var localizationsCreated: [String] = []
        var setsCreated = 0

        let byLocale = Dictionary(grouping: plan, by: \.locale)
        for locale in byLocale.keys.sorted() {
            let items = byLocale[locale] ?? []

            var localizationID = localizationIDs[locale]
            if localizationID == nil {
                output.info("Creating localization: \(locale)")
                localizationsCreated.append(locale)
                if !dryRun {
                    let created: APIResponse<VersionLocalization> = try await client.post(
                        "appStoreVersionLocalizations",
                        body: LocalizationCreateRequest(
                            data: LocalizationCreateData(
                                type: "appStoreVersionLocalizations",
                                attributes: LocalizationCreateAttributes(locale: locale),
                                relationships: LocalizationCreateRelationships(
                                    appStoreVersion: RelationshipRef(
                                        data: TypeIDRef(type: "appStoreVersions", id: versionID))))))
                    localizationID = created.data.id
                }
            }

            var setIDs: [String: String] = [:]
            if let localizationID {
                let sets: APIListResponse<ScreenshotSet> = try await client.getList(
                    "appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
                    queryItems: [
                        URLQueryItem(
                            name: "fields[appScreenshotSets]", value: "screenshotDisplayType")
                    ])
                for set in sets.data {
                    if let displayType = set.attributes?.screenshotDisplayType {
                        setIDs[displayType] = set.id
                    }
                }
            }

            let byDisplayType = Dictionary(grouping: items, by: \.displayType)
            for displayType in byDisplayType.keys.sorted() {
                var setID = setIDs[displayType]
                if setID == nil {
                    output.info(
                        "Creating screenshot set: \(displayType.displayTypeLabel) (\(locale))")
                    setsCreated += 1
                    if !dryRun, let localizationID {
                        let created: APIResponse<ScreenshotSet> = try await client.post(
                            "appScreenshotSets",
                            body: ScreenshotSetCreateRequest(
                                data: ScreenshotSetCreateData(
                                    type: "appScreenshotSets",
                                    attributes: ScreenshotSetCreateAttributes(
                                        screenshotDisplayType: displayType),
                                    relationships: ScreenshotSetCreateRelationships(
                                        appStoreVersionLocalization: RelationshipRef(
                                            data: TypeIDRef(
                                                type: "appStoreVersionLocalizations",
                                                id: localizationID))))))
                        setID = created.data.id
                    }
                }

                let files = (byDisplayType[displayType] ?? [])
                    .sorted { $0.file.lastPathComponent < $1.file.lastPathComponent }
                for item in files {
                    let name = "\(item.locale)/\(item.file.lastPathComponent)"
                    if dryRun {
                        output.info(
                            "[DRY RUN] Would upload \(name) → \(displayType.displayTypeLabel)")
                        continue
                    }
                    guard let setID else {
                        throw AppctlError.invalidResponse(
                            url: "appScreenshotSets",
                            reason: "No screenshot set ID for \(displayType) in \(locale).")
                    }
                    try await uploadOne(item, to: setID)
                    uploadedCount += 1
                    output.success("Uploaded \(name) (\(displayType.displayTypeLabel))")
                }
            }
        }
        return Summary(
            uploadedCount: uploadedCount, localizationsCreated: localizationsCreated,
            setsCreated: setsCreated)
    }

    private func uploadOne(_ item: PlannedScreenshot, to setID: String) async throws {
        let reserved: APIResponse<AppScreenshot> = try await client.post(
            "appScreenshots",
            body: ScreenshotCreateRequest(
                data: ScreenshotCreateData(
                    type: "appScreenshots",
                    attributes: ScreenshotCreateAttributes(
                        fileName: item.file.lastPathComponent, fileSize: item.fileSize),
                    relationships: ScreenshotCreateRelationships(
                        appScreenshotSet: RelationshipRef(
                            data: TypeIDRef(type: "appScreenshotSets", id: setID))))))
        let operations = reserved.data.attributes?.uploadOperations ?? []
        guard !operations.isEmpty else {
            throw AppctlError.invalidResponse(
                url: "appScreenshots", reason: "Reservation returned no upload operations.")
        }

        // Deterministic ordering for the work queue; completions may interleave.
        let ordered = operations.sorted { ($0.offset ?? 0) < ($1.offset ?? 0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < ordered.count && nextIndex < maxConcurrentPuts {
                let operation = ordered[nextIndex]
                group.addTask { try await self.uploadPart(operation, file: item.file) }
                nextIndex += 1
            }
            while try await group.next() != nil {
                if nextIndex < ordered.count {
                    let operation = ordered[nextIndex]
                    group.addTask { try await self.uploadPart(operation, file: item.file) }
                    nextIndex += 1
                }
            }
        }

        let checksum = try UploadFileAccess.md5Hex(of: item.file)
        let _: APIResponse<AppScreenshot> = try await client.patch(
            "appScreenshots/\(reserved.data.id)",
            body: ScreenshotCommitRequest(
                data: ScreenshotCommitData(
                    type: "appScreenshots", id: reserved.data.id,
                    attributes: ScreenshotCommitAttributes(
                        uploaded: true, sourceFileChecksum: checksum))))
    }

    private func uploadPart(_ operation: UploadOperation, file: URL) async throws {
        guard let url = operation.url, let offset = operation.offset, let length = operation.length
        else {
            throw AppctlError.invalidResponse(
                url: "appScreenshots", reason: "Upload operation is missing url/offset/length.")
        }
        let headers = Dictionary(
            uniqueKeysWithValues: (operation.requestHeaders ?? [])
                .compactMap { h in h.name.flatMap { n in h.value.map { (n, $0) } } })
        var lastError: Error?
        for attempt in 0..<maxPartAttempts {
            do {
                let body = try UploadFileAccess.readRange(of: file, offset: offset, length: Int(length))
                try await client.uploadBytes(
                    body, to: url, method: operation.method ?? "PUT", headers: headers)
                return
            } catch is CancellationError {
                throw AppctlError.operationCancelled
            } catch {
                lastError = error
                if attempt < maxPartAttempts - 1 {
                    try await Task.sleep(
                        for: RetryStrategy.delay(for: .transport, attempt: attempt, base: retryBaseDelay))
                }
            }
        }
        throw AppctlError.uploadPartFailed(
            partNumber: operation.partNumber ?? -1, attempts: maxPartAttempts,
            reason: lastError.map { String(describing: $0) } ?? "unknown")
    }
}
