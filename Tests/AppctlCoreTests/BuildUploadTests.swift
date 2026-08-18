import Crypto
import Foundation
import Testing

@testable import AppctlCore

/// Build Upload API acceptance tests: request ordering, resumability after a kill,
/// range-scoped part reads, retry policy, and --wait exit behavior — all via the mock.

private func quietOutput() -> OutputFormatter {
    OutputFormatter(format: .json, noColor: true)
}

/// A patterned archive in a temp dir: byte i = i % 251, so any slice is verifiable.
private func makeArchive(bytes: Int, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("Fixture.ipa")
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    return url
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("appctl-upload-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let buildUploadResponse = """
    {"data":{"type":"buildUploads","id":"UPLOAD-1","attributes":{"platform":"IOS",\
    "state":{"state":"AWAITING_UPLOAD"}}}}
    """

private func fileResponse(parts: [(url: String, offset: Int, length: Int, part: Int)]) -> String {
    let ops = parts.map {
        """
        {"method":"PUT","url":"\($0.url)","offset":\($0.offset),"length":\($0.length),\
        "partNumber":\($0.part),"requestHeaders":[{"name":"Content-Type","value":"application/octet-stream"}]}
        """
    }.joined(separator: ",")
    return """
        {"data":{"type":"buildUploadFiles","id":"FILE-1","attributes":{"fileName":"Fixture.ipa",\
        "assetType":"ASSET","uti":"com.apple.ipa","uploadOperations":[\(ops)]}}}
        """
}

private let commitResponse = """
    {"data":{"type":"buildUploadFiles","id":"FILE-1","attributes":{"fileName":"Fixture.ipa"}}}
    """

private let serverError = """
    {"errors":[{"status":"500","code":"UNEXPECTED_ERROR","title":"Something went wrong"}]}
    """

@Suite("Build upload service") struct BuildUploadServiceTests {

    @Test func createFilePutConfirmOrderingAndRangeScopedBodies() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 1024, in: dir)
        let contents = try Data(contentsOf: archive)

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(
            fileResponse(parts: [
                ("https://upload.example/part-1", 0, 512, 1),
                ("https://upload.example/part-2", 512, 512, 2),
            ]))
        await mock.queue(commitResponse)

        let result = try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let requests = await mock.requests
        #expect(
            requests.map { "\($0.method) \($0.path)" } == [
                "POST buildUploads",
                "POST buildUploadFiles",
                "PUT https://upload.example/part-1",
                "PUT https://upload.example/part-2",
                "PATCH buildUploadFiles/FILE-1",
            ], "create → file → PUT parts → confirm, in exactly that order")

        // Memory-safety review point: each PUT body must be exactly that operation's
        // byte range, proving parts are read range-scoped and never as the whole file.
        #expect(requests[2].body == contents.subdata(in: 0..<512))
        #expect(requests[3].body == contents.subdata(in: 512..<1024))
        #expect(
            requests[2].queryItems?.contains(
                URLQueryItem(name: "Content-Type", value: "application/octet-stream")) == true,
            "upload operation headers are forwarded verbatim")

        #expect(result.buildUploadID == "UPLOAD-1")
        #expect(result.partsUploaded == 2)
        #expect(
            !FileManager.default.fileExists(atPath: UploadSidecar.url(for: archive).path),
            "sidecar is removed after a successful commit")

        let create = try jsonObject(requests[0].body)
        #expect(nested(create, "data", "attributes")["cfBundleVersion"] as? String == "42")
        #expect(nested(create, "data", "relationships", "app", "data")["id"] as? String == "APP-1")
        let reserve = try jsonObject(requests[1].body)
        #expect(nested(reserve, "data", "attributes")["fileSize"] as? Int == 1024)
        #expect(nested(reserve, "data", "attributes")["assetType"] as? String == "ASSET")
    }

    @Test func commitCarriesUploadedFlagAndWholeFileMD5() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 256, in: dir)
        let expectedMD5 = md5Hex(try Data(contentsOf: archive))

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(fileResponse(parts: [("https://upload.example/only", 0, 256, 1)]))
        await mock.queue(commitResponse)

        _ = try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let commit = try jsonObject(await mock.requests.last?.body)
        #expect(nested(commit, "data", "attributes")["uploaded"] as? Bool == true)
        let file = nested(commit, "data", "attributes", "sourceFileChecksums", "file")
        #expect(file["algorithm"] as? String == "MD5")
        #expect(file["hash"] as? String == expectedMD5)
    }

    @Test func killedRunResumesUploadingOnlyMissingParts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 1024, in: dir)
        let contents = try Data(contentsOf: archive)

        // First run: part 2 fails all attempts, simulating a killed/broken upload.
        let firstMock = MockAppStoreConnectClient()
        await firstMock.queue(buildUploadResponse)
        await firstMock.queue(
            fileResponse(parts: [
                ("https://upload.example/part-1", 0, 512, 1),
                ("https://upload.example/part-2", 512, 512, 2),
            ]))
        await firstMock.failNext(
            "PUT", "https://upload.example/part-2", withErrorBody: serverError, times: 3)

        await #expect(throws: AppctlError.self) {
            try await BuildUploadService(client: firstMock, retryBaseDelay: 0).upload(
                archive: archive, appID: "APP-1", platform: "IOS",
                cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")
        }
        #expect(
            FileManager.default.fileExists(atPath: UploadSidecar.url(for: archive).path),
            "sidecar survives a failed run so the rerun can resume")

        // Rerun: no create, no reservation, no part-1 — only the missing part + commit.
        let rerunMock = MockAppStoreConnectClient()
        await rerunMock.queue(commitResponse)

        let result = try await BuildUploadService(client: rerunMock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let requests = await rerunMock.requests
        #expect(
            requests.map { "\($0.method) \($0.path)" } == [
                "PUT https://upload.example/part-2",
                "PATCH buildUploadFiles/FILE-1",
            ], "rerun must not re-create resources or re-upload completed parts")
        #expect(requests[0].body == contents.subdata(in: 512..<1024))
        #expect(result.partsSkipped == 1)
        #expect(result.partsUploaded == 1)
        #expect(!FileManager.default.fileExists(atPath: UploadSidecar.url(for: archive).path))
    }

    @Test func rebuiltArchiveInvalidatesStaleSidecar() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 512, in: dir)

        var stale = UploadSidecarState(fileSize: 512, fileMD5: "not-the-real-checksum", appID: "APP-1")
        stale.buildUploadID = "STALE-UPLOAD"
        stale.buildUploadFileID = "STALE-FILE"
        stale.completedParts = [1]
        try UploadSidecar.save(stale, for: archive)

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(fileResponse(parts: [("https://upload.example/only", 0, 512, 1)]))
        await mock.queue(commitResponse)

        _ = try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let methods = await mock.requests.map { "\($0.method) \($0.path)" }
        #expect(
            methods.first == "POST buildUploads",
            "a rebuilt file at the same path must start a fresh upload, not resume the stale one")
        #expect(methods.count == 4, "full flow runs: create, reserve, one PUT, commit")
    }

    @Test func expiredReservationDiscardsSidecarAndStartsFresh() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 512, in: dir)

        // Sidecar matches the file exactly, but its pending operation's pre-signed
        // URL expired long ago — PUTs and the commit against it can only fail.
        var expired = UploadSidecarState(
            fileSize: 512, fileMD5: try UploadFileAccess.md5Hex(of: archive), appID: "APP-1")
        expired.buildUploadID = "OLD-UPLOAD"
        expired.buildUploadFileID = "OLD-FILE"
        expired.operations = [
            UploadOperation(
                method: "PUT", url: "https://upload.example/stale", offset: 0, length: 512,
                partNumber: 1, expiration: "2020-01-01T00:00:00Z")
        ]
        try UploadSidecar.save(expired, for: archive)

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(fileResponse(parts: [("https://upload.example/fresh", 0, 512, 1)]))
        await mock.queue(commitResponse)

        _ = try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let methods = await mock.requests.map { "\($0.method) \($0.path)" }
        #expect(
            methods == [
                "POST buildUploads", "POST buildUploadFiles",
                "PUT https://upload.example/fresh", "PATCH buildUploadFiles/FILE-1",
            ], "expired reservations require a fresh upload, never a resume")
    }

    @Test func unexpiredReservationStillResumes() async throws {
        // Completed parts with past expirations must not force a restart — only
        // parts still pending care about their URL's lifetime.
        var state = UploadSidecarState(fileSize: 100, fileMD5: "x", appID: "a")
        state.operations = [
            UploadOperation(
                method: "PUT", url: "u", offset: 0, length: 50, partNumber: 1,
                expiration: "2020-01-01T00:00:00Z"),
            UploadOperation(
                method: "PUT", url: "u2", offset: 50, length: 50, partNumber: 2,
                expiration: "2999-01-01T00:00:00Z"),
        ]
        state.completedParts = [0]
        #expect(!BuildUploadService.hasExpiredPendingOperations(state))
        state.completedParts = []
        #expect(BuildUploadService.hasExpiredPendingOperations(state))
    }

    @Test func transientPartFailureRetriesThenSucceeds() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 128, in: dir)

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(fileResponse(parts: [("https://upload.example/only", 0, 128, 1)]))
        await mock.failNext("PUT", "https://upload.example/only", withErrorBody: serverError)
        await mock.queue(commitResponse)

        _ = try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
            archive: archive, appID: "APP-1", platform: "IOS",
            cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")

        let puts = await mock.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 2, "one failed attempt plus the successful retry")
    }

    @Test func partFailsAfterThreeAttempts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 128, in: dir)

        let mock = MockAppStoreConnectClient()
        await mock.queue(buildUploadResponse)
        await mock.queue(fileResponse(parts: [("https://upload.example/only", 0, 128, 1)]))
        await mock.failNext("PUT", "https://upload.example/only", withErrorBody: serverError, times: 3)

        await #expect(throws: AppctlError.self) {
            try await BuildUploadService(client: mock, retryBaseDelay: 0).upload(
                archive: archive, appID: "APP-1", platform: "IOS",
                cfBundleShortVersionString: "1.0", cfBundleVersion: "42", uti: "com.apple.ipa")
        }
        let puts = await mock.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 3, "retry budget is exactly three attempts per part")
    }
}

@Suite("Upload file access") struct UploadFileAccessTests {

    @Test func readRangeReturnsExactlyTheRequestedSlice() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 1000, in: dir)
        let contents = try Data(contentsOf: archive)

        let slice = try UploadFileAccess.readRange(of: archive, offset: 100, length: 50)
        #expect(slice == contents.subdata(in: 100..<150))
        #expect(slice.count == 50)
    }

    @Test func readRangePastEndOfFileThrowsInsteadOfShortReading() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 100, in: dir)

        #expect(throws: AppctlError.self) {
            _ = try UploadFileAccess.readRange(of: archive, offset: 90, length: 50)
        }
    }

    @Test func md5MatchesWholeFileDigest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(bytes: 4096, in: dir)

        #expect(try UploadFileAccess.md5Hex(of: archive) == md5Hex(try Data(contentsOf: archive)))
    }
}

@Suite("Builds upload --wait") struct BuildUploadWaitTests {

    private func buildsList(state: String) -> String {
        """
        {"data":[{"type":"builds","id":"build-1","attributes":{"version":"42",\
        "processingState":"\(state)"}}]}
        """
    }

    @Test func waitSucceedsWhenProcessingReachesValid() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(#"{"data":[]}"#)
        await mock.queue(buildsList(state: "PROCESSING"))
        await mock.queue(buildsList(state: "VALID"))

        let processed = try await BuildsCommand.Upload.waitForProcessing(
            client: mock, output: quietOutput(), appID: "APP-1", version: "42",
            pollInterval: .zero, maxPolls: 5)

        #expect(processed.state == "VALID")
        #expect(processed.version == "42")
        let requests = await mock.requests
        #expect(requests.count == 3, "polls until the terminal state, including before the build appears")
        #expect(requests[0].path == "builds")
        #expect(
            requests[0].queryItems?.contains(URLQueryItem(name: "filter[version]", value: "42")) == true,
            "with a known CFBundleVersion the poll pins the exact build")
    }

    @Test func waitThrowsOnFailedSoExitCodeIsNonZero() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(buildsList(state: "FAILED"))

        await #expect(throws: AppctlError.self) {
            try await BuildsCommand.Upload.waitForProcessing(
                client: mock, output: quietOutput(), appID: "APP-1", version: "42",
                pollInterval: .zero, maxPolls: 5)
        }
    }

    @Test func waitThrowsOnInvalid() async throws {
        let mock = MockAppStoreConnectClient()
        await mock.queue(buildsList(state: "INVALID"))

        await #expect(throws: AppctlError.self) {
            try await BuildsCommand.Upload.waitForProcessing(
                client: mock, output: quietOutput(), appID: "APP-1", version: "42",
                pollInterval: .zero, maxPolls: 5)
        }
    }

    @Test func waitTimesOutAfterMaxPolls() async throws {
        let mock = MockAppStoreConnectClient()
        for _ in 0..<3 { await mock.queue(buildsList(state: "PROCESSING")) }

        await #expect(throws: AppctlError.self) {
            try await BuildsCommand.Upload.waitForProcessing(
                client: mock, output: quietOutput(), appID: "APP-1", version: "42",
                pollInterval: .zero, maxPolls: 3)
        }
    }
}

@Suite("altool backend") struct AltoolBackendTests {

    @Test func invocationIsExactAndStable() {
        let invocation = AltoolBackend.invocation(
            file: "/tmp/MyApp.ipa", altoolType: "ios", appleID: "123456", bundleID: "com.example.app",
            shortVersion: "1.2.3", bundleVersion: "42", keyID: "ABC123", issuerID: "issuer-1")
        #expect(
            invocation == [
                "xcrun", "altool", "--upload-package", "/tmp/MyApp.ipa",
                "--type", "ios",
                "--apple-id", "123456",
                "--bundle-id", "com.example.app",
                "--bundle-short-version-string", "1.2.3",
                "--bundle-version", "42",
                "--apiKey", "ABC123",
                "--apiIssuer", "issuer-1",
            ], "--dry-run prints exactly this invocation")
    }

    @Test func platformMapsToAltoolTypeVocabulary() {
        #expect(AltoolBackend.altoolType(forPlatform: "ios") == "ios")
        #expect(AltoolBackend.altoolType(forPlatform: "macos") == "macos")
        #expect(AltoolBackend.altoolType(forPlatform: "tvos") == "appletvos")
        #expect(AltoolBackend.altoolType(forPlatform: "visionos") == "visionos")
        #expect(AltoolBackend.altoolType(forPlatform: "watchos") == nil)
    }

    @Test func nonZeroExitBecomesWhatWhyFixError() async throws {
        struct FailingRunner: ProcessRunner {
            func run(
                executable: String, arguments: [String],
                onOutputLine: @escaping @Sendable (String) -> Void
            ) async throws -> Int32 {
                onOutputLine("*** Error: something altool-ish went wrong")
                return 1
            }
        }
        await #expect(throws: AppctlError.self) {
            try await AltoolBackend.run(
                invocation: ["xcrun", "altool", "--upload-package", "x"],
                runner: FailingRunner(), output: quietOutput())
        }
    }

    @Test func zeroExitSucceeds() async throws {
        struct OKRunner: ProcessRunner {
            func run(
                executable: String, arguments: [String],
                onOutputLine: @escaping @Sendable (String) -> Void
            ) async throws -> Int32 { 0 }
        }
        try await AltoolBackend.run(
            invocation: ["xcrun", "altool", "--upload-package", "x"],
            runner: OKRunner(), output: quietOutput())
    }
}
