import Foundation

/// Offline stand-in for `APIClient`, selected by the hidden `--mock` flag so users can
/// rehearse commands without credentials or network. Serves canned JSON:API responses
/// keyed by method and path; every identifier is deliberately fake ("MOCK-…",
/// "mock-issuer") so fixture output can never be mistaken for real App Store Connect
/// data. Stateless by design — routing is pure, so no isolation is needed.
struct FixtureClient: AppStoreConnectClient {

    /// Credentials a user would immediately recognize as fake if they surface in
    /// output (auth status, verbose logs).
    static func mockConfig(verbose: Bool, noColor: Bool) -> AppctlConfig {
        AppctlConfig(
            keyID: "MOCK-KEY-ID", issuerID: "mock-issuer",
            defaultAppID: "MOCK-APP-ID", defaultBundleID: "com.example.mock-app",
            verbose: verbose, noColor: noColor)
    }

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]?) async throws -> T {
        try decode(fixture(method: "GET", path: path), for: path)
    }

    func post<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        // The build-upload reservation echoes the caller's fileSize back as the single
        // upload operation's length; a hardcoded length would fail the service's
        // exact-range read for any real archive.
        if path == "buildUploadFiles", let size = Self.requestedFileSize(from: body) {
            return try decode(Data(Self.buildUploadFile(fileSize: size).utf8), for: path)
        }
        return try decode(fixture(method: "POST", path: path), for: path)
    }

    private static func requestedFileSize(from body: Encodable & Sendable) -> Int64? {
        guard let data = try? JSONEncoder().encode(FixtureEncodableBox(body)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let attributes = (object["data"] as? [String: Any])?["attributes"] as? [String: Any]
        else { return nil }
        return (attributes["fileSize"] as? NSNumber)?.int64Value
    }

    func patch<T: Decodable>(_ path: String, body: Encodable & Sendable) async throws -> T {
        try decode(fixture(method: "PATCH", path: path), for: path)
    }

    func delete(_ path: String) async throws {}
    func postVoid(_ path: String, body: Encodable & Sendable) async throws {}
    func patchVoid(_ path: String, body: Encodable & Sendable) async throws {}
    func uploadBytes(_ body: Data, to url: String, method: String, headers: [String: String]) async throws {}

    private func decode<T: Decodable>(_ data: Data, for path: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw AppctlError.invalidResponse(
                url: "mock://\(path)", reason: "Fixture did not match the expected shape: \(error)")
        }
    }

    private func fixture(method: String, path: String) throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts.first ?? "") {
        case ("GET", "apps"):
            if parts.count == 1 { return Data(Self.appsList.utf8) }
            if parts.last == "reviewSubmissions" { return Data(Self.emptyList.utf8) }
            if parts.last == "appStoreVersions" { return Data(Self.versionsList.utf8) }
            if parts.count == 2 { return Data(Self.appDetail.utf8) }
        case ("GET", "builds"):
            return Data(parts.count == 1 ? Self.buildsList.utf8 : Self.buildDetail.utf8)
        case ("GET", "appStoreVersions"):
            if parts.last == "app" { return Data(Self.appDetail.utf8) }
            if parts.count == 2 { return Data(Self.versionDetail.utf8) }
        case ("POST", "appStoreVersions"), ("PATCH", "appStoreVersions"):
            return Data(Self.versionDetail.utf8)
        case ("PATCH", "builds"):
            return Data(Self.buildDetail.utf8)
        case ("POST", "reviewSubmissions"), ("PATCH", "reviewSubmissions"):
            return Data(Self.reviewSubmission.utf8)
        case ("POST", "reviewSubmissionItems"):
            return Data(Self.reviewSubmissionItem.utf8)
        case ("GET", "buildUploads"), ("POST", "buildUploads"):
            return Data(Self.buildUpload.utf8)
        case ("PATCH", "buildUploadFiles"):
            return Data(Self.buildUploadFileCommitted.utf8)
        default:
            break
        }
        throw AppctlError.invalidResponse(
            url: "mock://\(path)",
            reason: "The offline fixture set has no response for '\(method) \(path)'.")
    }

    private static let appResource = """
        {"type":"apps","id":"MOCK-APP-ID","attributes":{"name":"Mock App","bundleId":"com.example.mock-app",\
        "sku":"MOCK-SKU","primaryLocale":"en-US"}}
        """
    private static let appsList = #"{"data":[\#(appResource)]}"#
    private static let appDetail = #"{"data":\#(appResource)}"#

    private static let buildResource = """
        {"type":"builds","id":"MOCK-BUILD-ID","attributes":{"version":"42","uploadedDate":"2026-01-01T00:00:00Z",\
        "expired":false,"minOsVersion":"13.0","processingState":"VALID","usesNonExemptEncryption":false}}
        """
    private static let buildsList = #"{"data":[\#(buildResource)]}"#
    private static let buildDetail = #"{"data":\#(buildResource)}"#

    private static let versionResource = """
        {"type":"appStoreVersions","id":"MOCK-VERSION-ID","attributes":{"versionString":"9.9.9",\
        "platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}
        """
    private static let versionsList = #"{"data":[\#(versionResource)]}"#
    private static let versionDetail = #"{"data":\#(versionResource)}"#

    private static let reviewSubmission = """
        {"data":{"type":"reviewSubmissions","id":"MOCK-SUBMISSION-ID",\
        "attributes":{"platform":"IOS","state":"WAITING_FOR_REVIEW"}}}
        """
    private static let reviewSubmissionItem = """
        {"data":{"type":"reviewSubmissionItems","id":"MOCK-ITEM-ID","attributes":{"state":"READY_FOR_REVIEW"}}}
        """
    private static let buildUpload = """
        {"data":{"type":"buildUploads","id":"MOCK-UPLOAD-ID","attributes":{"cfBundleShortVersionString":"1.0",\
        "cfBundleVersion":"42","platform":"IOS","state":{"state":"COMPLETE"}},\
        "relationships":{"build":{"data":{"type":"builds","id":"MOCK-BUILD-ID"}}}}}
        """
    private static func buildUploadFile(fileSize: Int64) -> String {
        """
        {"data":{"type":"buildUploadFiles","id":"MOCK-UPLOAD-FILE-ID","attributes":{"fileName":"Mock.ipa",\
        "fileSize":\(fileSize),"assetType":"ASSET","uti":"com.apple.ipa","uploadOperations":[{"method":"PUT",\
        "url":"https://mock.upload.invalid/part-1","offset":0,"length":\(fileSize),"partNumber":1,\
        "requestHeaders":[{"name":"Content-Type","value":"application/octet-stream"}]}]}}}
        """
    }
    private static let buildUploadFileCommitted = """
        {"data":{"type":"buildUploadFiles","id":"MOCK-UPLOAD-FILE-ID","attributes":{"fileName":"Mock.ipa",\
        "fileSize":1024,"assetType":"ASSET","uti":"com.apple.ipa"}}}
        """
    private static let emptyList = #"{"data":[]}"#
}

private struct FixtureEncodableBox: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}
