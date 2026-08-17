import Foundation

/// Minimal audit hook for the `api` command only: appends one NDJSON line per
/// executed mutation to `~/.appctl/audit.log`. Deliberately narrow — task V9 owns
/// the full audit subsystem (snapshot capture for undo, `appctl history`, final
/// schema, cross-command rollout) and this hook must not grow features ahead of
/// that design.
struct APIAuditTrail: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".appctl/audit.log")
    }

    /// Records one executed mutation. Only successful requests are recorded:
    /// a failed call changed nothing, and richer outcome tracking is V9's call.
    func record(method: String, url: String) throws {
        let formatter = ISO8601DateFormatter()
        let entry: [String: JSONValue] = [
            "timestamp": .string(formatter.string(from: Date())),
            "command": .string("api"),
            "method": .string(method),
            "url": .string(url),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(Data("\n".utf8))

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch let error as AppctlError {
            throw error
        } catch {
            throw AppctlError.fileWriteError(path: fileURL.path, reason: error.localizedDescription)
        }
    }
}
