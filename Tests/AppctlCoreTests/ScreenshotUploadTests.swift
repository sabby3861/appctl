import Crypto
import Foundation
import Testing

@testable import AppctlCore

/// Screenshot upload acceptance tests: reserve→PUT→commit ordering with the correct
/// MD5, pre-network dimension validation, and retry/concurrency behavior — all mocked.

private func quietOutput() -> OutputFormatter {
    OutputFormatter(format: .json, noColor: true)
}

private func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A fastlane-layout screenshots dir with one valid 6.7" PNG in en-US.
private func makeScreenshotsDir() throws -> (dir: URL, file: URL, bytes: Data) {
    let dir = try makeTempDir("screenshots")
    let locale = dir.appendingPathComponent("en-US")
    try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
    let bytes = ImageFixtures.png(width: 1290, height: 2796, colorType: 2)
    let file = try ImageFixtures.write(bytes, named: "01_home.png", in: locale)
    return (dir, file, bytes)
}

private let versionListResponse = """
    {"data":[{"type":"appStoreVersions","id":"VER-1","attributes":{"versionString":"2.1.0"}}]}
    """
private let localizationListResponse = """
    {"data":[{"type":"appStoreVersionLocalizations","id":"LOC-1","attributes":{"locale":"en-US"}}]}
    """
private let emptySetsResponse = #"{"data":[]}"#
private let setCreateResponse = """
    {"data":{"type":"appScreenshotSets","id":"SET-1",\
    "attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}}
    """

private func reserveResponse(operations: [(url: String, offset: Int, length: Int)]) -> String {
    let ops = operations.map {
        """
        {"method":"PUT","url":"\($0.url)","offset":\($0.offset),"length":\($0.length),\
        "partNumber":1,"requestHeaders":[{"name":"Content-Type","value":"image/png"}]}
        """
    }.joined(separator: ",")
    return """
        {"data":{"type":"appScreenshots","id":"SS-1",\
        "attributes":{"fileName":"01_home.png","uploadOperations":[\(ops)]}}}
        """
}

private let commitResponse = """
    {"data":{"type":"appScreenshots","id":"SS-1","attributes":{"fileName":"01_home.png"}}}
    """

private let serverError = """
    {"errors":[{"status":"500","code":"UNEXPECTED_ERROR","title":"Something went wrong"}]}
    """

@Suite("Screenshot upload") struct ScreenshotUploadTests {

    @Test func reservePutCommitWithCorrectMD5() async throws {
        let (dir, _, bytes) = try makeScreenshotsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(localizationListResponse)
        await mock.queue(emptySetsResponse)
        await mock.queue(setCreateResponse)
        await mock.queue(reserveResponse(operations: [("https://upload.example/ss-1", 0, bytes.count)]))
        await mock.queue(commitResponse)

        let summary = try await ScreenshotsCommand.Upload.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false, retryBaseDelay: 0)

        #expect(summary.uploadedCount == 1)
        #expect(summary.setsCreated == 1)
        #expect(summary.localizationsCreated.isEmpty)

        let requests = await mock.requests
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST", "POST", "PUT", "PATCH"])
        #expect(requests[0].path == "apps/APP-1/appStoreVersions")
        #expect(requests[1].path == "appStoreVersions/VER-1/appStoreVersionLocalizations")
        #expect(requests[2].path == "appStoreVersionLocalizations/LOC-1/appScreenshotSets")
        #expect(requests[3].path == "appScreenshotSets")

        let setBody = try jsonObject(requests[3].body)
        #expect(
            nested(setBody, "data", "attributes")["screenshotDisplayType"] as? String
                == "APP_IPHONE_67")
        #expect(
            nested(setBody, "data", "relationships", "appStoreVersionLocalization", "data")["id"]
                as? String == "LOC-1")

        let reserveBody = try jsonObject(requests[4].body)
        #expect(requests[4].path == "appScreenshots")
        #expect(nested(reserveBody, "data", "attributes")["fileName"] as? String == "01_home.png")
        #expect(nested(reserveBody, "data", "attributes")["fileSize"] as? Int == bytes.count)
        #expect(
            nested(reserveBody, "data", "relationships", "appScreenshotSet", "data")["id"]
                as? String == "SET-1")

        #expect(requests[5].path == "https://upload.example/ss-1")
        #expect(requests[5].body == bytes)

        #expect(requests[6].path == "appScreenshots/SS-1")
        let commitBody = try jsonObject(requests[6].body)
        #expect(nested(commitBody, "data", "attributes")["uploaded"] as? Bool == true)
        #expect(
            nested(commitBody, "data", "attributes")["sourceFileChecksum"] as? String
                == md5Hex(bytes))
    }

    @Test func wrongDimensionsRejectedBeforeAnyNetworkCall() async throws {
        let dir = try makeTempDir("screenshots")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        _ = try ImageFixtures.write(
            ImageFixtures.png(width: 1000, height: 1000, colorType: 2), named: "bad.png", in: locale)
        _ = try ImageFixtures.write(
            ImageFixtures.png(width: 1290, height: 2796, colorType: 2), named: "good.png", in: locale)

        let mock = MockAppStoreConnectClient()
        var message = ""
        do {
            _ = try await ScreenshotsCommand.Upload.execute(
                client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
                path: dir.path, dryRun: false, retryBaseDelay: 0)
            Issue.record("Expected validation failure")
        } catch let error as AppctlError {
            message = error.diagnosticMessage
        }
        // Detected dimensions plus the accepted-size listing, and zero requests.
        #expect(message.contains("got 1000×1000"))
        #expect(message.contains("1320×2868"))
        #expect(message.contains("en-US/bad.png"))
        let requests = await mock.requests
        #expect(requests.isEmpty)
    }

    @Test func alphaPNGAndDisguisedHEICRejected() throws {
        let dir = try makeTempDir("screenshots")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locale = dir.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        _ = try ImageFixtures.write(
            ImageFixtures.png(width: 1290, height: 2796, colorType: 6), named: "alpha.png",
            in: locale)
        _ = try ImageFixtures.write(ImageFixtures.heic(), named: "disguised.png", in: locale)

        var message = ""
        do {
            _ = try ScreenshotUploadService.validate(directory: dir)
            Issue.record("Expected validation failure")
        } catch let error as AppctlError {
            message = error.diagnosticMessage
        }
        #expect(message.contains("alpha channel"))
        #expect(message.contains("HEIC"))
    }

    @Test func nonImageFilesAreIgnoredNotSilent() throws {
        let (dir, _, _) = try makeScreenshotsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("junk".utf8).write(
            to: dir.appendingPathComponent("en-US").appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))

        let result = try ScreenshotUploadService.validate(directory: dir)
        #expect(result.plan.count == 1)
        #expect(result.ignored.contains("en-US/notes.txt"))
        #expect(result.ignored.contains(".DS_Store"))
    }

    @Test func multiPartOperationsUploadRangeScopedBodies() async throws {
        let (dir, _, bytes) = try makeScreenshotsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let half = bytes.count / 2

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(localizationListResponse)
        await mock.queue(emptySetsResponse)
        await mock.queue(setCreateResponse)
        await mock.queue(
            reserveResponse(operations: [
                ("https://upload.example/part-1", 0, half),
                ("https://upload.example/part-2", half, bytes.count - half),
            ]))
        await mock.queue(commitResponse)

        _ = try await ScreenshotsCommand.Upload.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false, retryBaseDelay: 0)

        // Concurrent PUT completion order is nondeterministic — assert by URL.
        let requests = await mock.requests
        let puts = requests.filter { $0.method == "PUT" }
        #expect(puts.count == 2)
        #expect(puts.first { $0.path == "https://upload.example/part-1" }?.body == bytes.prefix(half))
        #expect(
            puts.first { $0.path == "https://upload.example/part-2" }?.body
                == bytes.suffix(bytes.count - half))
        // The commit must come after every PUT.
        let patchIndex = try #require(requests.firstIndex { $0.method == "PATCH" })
        let lastPutIndex = try #require(requests.lastIndex { $0.method == "PUT" })
        #expect(patchIndex > lastPutIndex)
    }

    @Test func failedPutRetriesThenSucceeds() async throws {
        let (dir, _, bytes) = try makeScreenshotsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        await mock.queue(localizationListResponse)
        await mock.queue(emptySetsResponse)
        await mock.queue(setCreateResponse)
        await mock.queue(reserveResponse(operations: [("https://upload.example/ss-1", 0, bytes.count)]))
        await mock.queue(commitResponse)
        await mock.failNext("PUT", "https://upload.example/ss-1", withErrorBody: serverError)

        let summary = try await ScreenshotsCommand.Upload.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: false, retryBaseDelay: 0)

        #expect(summary.uploadedCount == 1)
        let puts = await mock.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 2)
    }

    @Test func dryRunWithMissingLocalizationMakesNoMutatingRequests() async throws {
        let (dir, _, _) = try makeScreenshotsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockAppStoreConnectClient()
        await mock.queue(versionListResponse)
        // No localizations exist yet — en-US must be reported as created.
        await mock.queue(#"{"data":[]}"#)

        let summary = try await ScreenshotsCommand.Upload.execute(
            client: mock, output: quietOutput(), appId: "APP-1", version: "2.1.0",
            path: dir.path, dryRun: true, retryBaseDelay: 0)

        #expect(summary.uploadedCount == 0)
        #expect(summary.localizationsCreated == ["en-US"])
        #expect(summary.setsCreated == 1)
        let requests = await mock.requests
        #expect(requests.allSatisfy { $0.method == "GET" })
    }
}
