import Foundation

/// Orchestrates the Build Upload API flow: create buildUpload → reserve
/// buildUploadFile → PUT each operation's byte range → commit with the whole-file
/// checksum. Progress and completed parts are persisted to a sidecar after every
/// part, so a killed run resumes with only the missing parts.
///
/// Parts upload sequentially. Parallelism: candidate future optimization — the API
/// permits concurrent part uploads, but sequential is deterministic and resumable,
/// which wins for v1.
public struct BuildUploadService: Sendable {
    private let client: any AppStoreConnectClient
    /// Base delay for per-part retry backoff; tests pass 0 to avoid sleeping.
    private let retryBaseDelay: TimeInterval
    private let maxPartAttempts = 3

    public init(client: any AppStoreConnectClient, retryBaseDelay: TimeInterval = 1.0) {
        self.client = client
        self.retryBaseDelay = retryBaseDelay
    }

    public struct Result: Sendable {
        public let buildUploadID: String
        public let partsUploaded: Int
        public let partsSkipped: Int
    }

    public func upload(
        archive: URL, appID: String, platform: String,
        cfBundleShortVersionString: String, cfBundleVersion: String, uti: String,
        progress: @Sendable (UploadProgress) -> Void = { _ in }
    ) async throws -> Result {
        let fileSize = try UploadFileAccess.fileSize(of: archive)
        let fileMD5 = try UploadFileAccess.md5Hex(of: archive)

        var state: UploadSidecarState
        if let existing = UploadSidecar.load(for: archive),
            existing.matches(fileSize: fileSize, fileMD5: fileMD5, appID: appID)
        {
            if Self.hasExpiredPendingOperations(existing) {
                // Expired pre-signed URLs fail both uploads and the commit, so the
                // only way forward is a fresh reservation — resuming would burn the
                // retry budget on requests that can never succeed.
                await client.logDebug("Sidecar upload operations have expired; starting a fresh upload.")
                state = UploadSidecarState(fileSize: fileSize, fileMD5: fileMD5, appID: appID)
            } else {
                state = existing
                await client.logDebug(
                    "Resuming upload from sidecar: \(existing.completedParts.count) part(s) already uploaded.")
            }
        } else {
            state = UploadSidecarState(fileSize: fileSize, fileMD5: fileMD5, appID: appID)
        }

        let buildUploadID: String
        if let id = state.buildUploadID {
            buildUploadID = id
        } else {
            let response: APIResponse<BuildUpload> = try await client.post(
                "buildUploads",
                body: BuildUploadCreateRequest(
                    data: BuildUploadCreateData(
                        type: "buildUploads",
                        attributes: BuildUploadCreateAttributes(
                            cfBundleShortVersionString: cfBundleShortVersionString,
                            cfBundleVersion: cfBundleVersion, platform: platform),
                        relationships: BuildUploadCreateRelationships(
                            app: RelationshipRef(data: TypeIDRef(type: "apps", id: appID))))))
            buildUploadID = response.data.id
            state.buildUploadID = buildUploadID
            try UploadSidecar.save(state, for: archive)
        }

        let fileID: String
        let operations: [UploadOperation]
        if let id = state.buildUploadFileID, let saved = state.operations {
            fileID = id
            operations = saved
        } else {
            let response: APIResponse<BuildUploadFile> = try await client.post(
                "buildUploadFiles",
                body: BuildUploadFileCreateRequest(
                    data: BuildUploadFileCreateData(
                        type: "buildUploadFiles",
                        attributes: BuildUploadFileCreateAttributes(
                            assetType: "ASSET", fileName: archive.lastPathComponent,
                            fileSize: fileSize, uti: uti),
                        relationships: BuildUploadFileCreateRelationships(
                            buildUpload: RelationshipRef(
                                data: TypeIDRef(type: "buildUploads", id: buildUploadID))))))
            fileID = response.data.id
            operations = response.data.attributes?.uploadOperations ?? []
            guard !operations.isEmpty else {
                throw AppctlError.invalidResponse(
                    url: "buildUploadFiles", reason: "Reservation returned no upload operations.")
            }
            state.buildUploadFileID = fileID
            state.operations = operations
            try UploadSidecar.save(state, for: archive)
        }

        // Sorted by offset so part order — and therefore the mocked request log — is
        // deterministic regardless of how the server orders operations. Completion is
        // keyed on offset, which is mandatory and unique per part; partNumber is
        // optional and a shared fallback key would collapse all parts together.
        let ordered = operations.sorted { ($0.offset ?? 0) < ($1.offset ?? 0) }
        let completed = Set(state.completedParts)
        let partsSkipped = ordered.count { completed.contains($0.offset ?? -1) }
        var completedBytes = ordered.filter { completed.contains($0.offset ?? -1) }
            .reduce(Int64(0)) { $0 + ($1.length ?? 0) }
        var completedParts = partsSkipped
        progress(
            UploadProgress(
                completedParts: completedParts, totalParts: ordered.count,
                completedBytes: completedBytes, totalBytes: fileSize))

        for operation in ordered {
            if completed.contains(operation.offset ?? -1) { continue }
            try await uploadPart(operation, archive: archive)
            state.completedParts.append(operation.offset ?? -1)
            try UploadSidecar.save(state, for: archive)
            completedParts += 1
            completedBytes += operation.length ?? 0
            progress(
                UploadProgress(
                    completedParts: completedParts, totalParts: ordered.count,
                    completedBytes: completedBytes, totalBytes: fileSize))
        }

        let _: APIResponse<BuildUploadFile> = try await client.patch(
            "buildUploadFiles/\(fileID)",
            body: BuildUploadFileCommitRequest(
                data: BuildUploadFileCommitData(
                    type: "buildUploadFiles", id: fileID,
                    attributes: BuildUploadFileCommitAttributes(
                        uploaded: true,
                        sourceFileChecksums: SourceFileChecksums(
                            file: FileChecksumValue(algorithm: "MD5", hash: fileMD5))))))

        UploadSidecar.clear(for: archive)
        return Result(
            buildUploadID: buildUploadID,
            partsUploaded: ordered.count - partsSkipped, partsSkipped: partsSkipped)
    }

    /// True when any part still to be uploaded carries an `expiration` in the past.
    static func hasExpiredPendingOperations(_ state: UploadSidecarState, now: Date = Date()) -> Bool {
        let completed = Set(state.completedParts)
        return (state.operations ?? []).contains { operation in
            guard !completed.contains(operation.offset ?? -1),
                let expiration = operation.expiration.flatMap(Self.parseISO8601)
            else { return false }
            return expiration < now
        }
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private func uploadPart(_ operation: UploadOperation, archive: URL) async throws {
        guard let url = operation.url, let offset = operation.offset, let length = operation.length
        else {
            throw AppctlError.invalidResponse(
                url: "buildUploadFiles", reason: "Upload operation is missing url/offset/length.")
        }
        let headers = Dictionary(
            uniqueKeysWithValues: (operation.requestHeaders ?? [])
                .compactMap { h in h.name.flatMap { n in h.value.map { (n, $0) } } })
        var lastError: Error?
        for attempt in 0..<maxPartAttempts {
            do {
                // Range-scoped read (see UploadFileAccess): exactly this operation's
                // bytes, never the whole archive.
                let body = try UploadFileAccess.readRange(of: archive, offset: offset, length: Int(length))
                try await client.uploadBytes(
                    body, to: url, method: operation.method ?? "PUT", headers: headers)
                return
            } catch is CancellationError {
                throw AppctlError.operationCancelled
            } catch {
                lastError = error
                if attempt < maxPartAttempts - 1 {
                    try await Task.sleep(for: APIClient.backoffDelay(attempt: attempt, base: retryBaseDelay))
                }
            }
        }
        throw AppctlError.uploadPartFailed(
            partNumber: operation.partNumber ?? -1, attempts: maxPartAttempts,
            reason: lastError.map { String(describing: $0) } ?? "unknown")
    }
}
