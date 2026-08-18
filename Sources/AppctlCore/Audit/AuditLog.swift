import Foundation

/// The append-only audit log: one NDJSON file per month under `~/.appctl/audit/`.
/// Appends go through `open(2)` with `O_APPEND` so concurrent appctl processes
/// interleave whole lines rather than corrupting each other; the actor serializes
/// writers within this process.
actor AuditLog {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appctl/audit")
    }

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    func append(_ entry: AuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw AppctlError.fileWriteError(path: directory.path, reason: error.localizedDescription)
        }
        let fileURL = directory.appendingPathComponent(Self.fileName(for: entry.ts))
        try Self.appendLine(line, to: fileURL)
    }

    /// `2026-08-18T…` → `2026-08.ndjson`; a timestamp too short to carry a month
    /// cannot occur from our own writer but still lands in a parseable file.
    static func fileName(for ts: String) -> String {
        "\(ts.prefix(7)).ndjson"
    }

    private static func appendLine(_ line: Data, to fileURL: URL) throws {
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw AppctlError.fileWriteError(
                path: fileURL.path, reason: String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: line)
        } catch {
            throw AppctlError.fileWriteError(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    /// Reads every monthly file back, oldest file first. Lines that fail to parse
    /// are counted rather than fatal: a corrupt line must not hide the rest of the
    /// history, and the count lets `appctl history` surface the damage as a warning.
    static func readEntries(in directory: URL) throws -> (entries: [AuditEntry], malformed: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return ([], 0) }
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "ndjson" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw AppctlError.fileNotReadable(path: directory.path)
        }
        let decoder = JSONDecoder()
        var entries: [AuditEntry] = []
        var malformed = 0
        for file in files {
            guard let data = fm.contents(atPath: file.path) else {
                throw AppctlError.fileNotReadable(path: file.path)
            }
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(AuditEntry.self, from: Data(line)) {
                    entries.append(entry)
                } else {
                    malformed += 1
                }
            }
        }
        return (entries, malformed)
    }
}
