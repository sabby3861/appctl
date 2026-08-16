import Foundation

/// Resumable-upload state persisted next to the archive (`MyApp.ipa.appctl-upload.json`).
/// Keyed on file size + whole-file MD5 so a rebuilt IPA at the same path invalidates
/// stale state instead of committing a half-old, half-new upload.
public struct UploadSidecarState: Codable, Sendable {
    public var schemaVersion: Int
    public let fileSize: Int64
    public let fileMD5: String
    public let appID: String
    public var buildUploadID: String?
    public var buildUploadFileID: String?
    public var operations: [UploadOperation]?
    public var completedParts: [Int64]

    public init(fileSize: Int64, fileMD5: String, appID: String) {
        self.schemaVersion = 1
        self.fileSize = fileSize
        self.fileMD5 = fileMD5
        self.appID = appID
        self.buildUploadID = nil
        self.buildUploadFileID = nil
        self.operations = nil
        self.completedParts = []
    }

    public func matches(fileSize: Int64, fileMD5: String, appID: String) -> Bool {
        self.fileSize == fileSize && self.fileMD5 == fileMD5 && self.appID == appID
    }
}

public enum UploadSidecar {
    public static func url(for archive: URL) -> URL {
        archive.appendingPathExtension("appctl-upload.json")
    }

    /// Unreadable or corrupt sidecars are treated as absent — resuming is an
    /// optimization, never a correctness requirement.
    public static func load(for archive: URL) -> UploadSidecarState? {
        guard let data = try? Data(contentsOf: url(for: archive)) else { return nil }
        return try? JSONDecoder().decode(UploadSidecarState.self, from: data)
    }

    public static func save(_ state: UploadSidecarState, for archive: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(state).write(to: url(for: archive), options: .atomic)
        } catch {
            throw AppctlError.fileWriteError(path: url(for: archive).path, reason: error.localizedDescription)
        }
    }

    public static func clear(for archive: URL) {
        try? FileManager.default.removeItem(at: url(for: archive))
    }
}
