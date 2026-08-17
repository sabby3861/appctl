import Foundation

/// Shared `.appctl.toml` assembly and persistence, used by every command that
/// writes config (`init`, `migrate`). Rendering is deterministic so repeated
/// runs produce byte-identical files; writing always backs up and restricts
/// permissions, because the file can reference a private key path.
enum ConfigWriter {
    /// Renders a flat `section.key` map as sectioned TOML, deterministically:
    /// known sections in canonical order, other sections alphabetically after,
    /// keys alphabetical within each section.
    static func renderTOML(_ values: [String: String]) -> String {
        let canonical = ["auth", "app", "paths", "output", "network"]
        var sections: [String: [(key: String, value: String)]] = [:]
        var topLevel: [(key: String, value: String)] = []
        for (fullKey, value) in values {
            if let dot = fullKey.firstIndex(of: ".") {
                let section = String(fullKey[..<dot])
                let key = String(fullKey[fullKey.index(after: dot)...])
                sections[section, default: []].append((key, value))
            } else {
                topLevel.append((fullKey, value))
            }
        }
        var lines = ["# appctl configuration"]
        for (key, value) in topLevel.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key) = \(tomlLiteral(value))")
        }
        let order =
            canonical.filter { sections[$0] != nil }
            + sections.keys.filter { !canonical.contains($0) }.sorted()
        for section in order {
            lines.append("")
            lines.append("[\(section)]")
            for (key, value) in (sections[section] ?? []).sorted(by: { $0.key < $1.key }) {
                lines.append("\(key) = \(tomlLiteral(value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func tomlLiteral(_ value: String) -> String {
        if value == "true" || value == "false" || Int(value) != nil || Double(value) != nil {
            return value
        }
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Writes the rendered config with 0600 permissions, backing up any existing
    /// file to `<path>.bak` first (overwritten each run). Returns the backup path
    /// when one was written.
    static func writeConfig(_ content: String, to path: String, output: OutputFormatter) throws -> String? {
        let fm = FileManager.default
        var backupPath: String?
        if fm.fileExists(atPath: path) {
            let bak = path + ".bak"
            if fm.fileExists(atPath: bak) { try fm.removeItem(atPath: bak) }
            try fm.copyItem(atPath: path, toPath: bak)
            backupPath = bak
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw AppctlError.fileWriteError(path: path, reason: error.localizedDescription)
        }
        // Restrict to owner read/write — the file references the path to a private key.
        do {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path)
        } catch {
            output.warning(
                "Saved \(path) but could not set 0600 permissions (\(error.localizedDescription)). "
                    + "Consider running: chmod 600 \(path)")
        }
        return backupPath
    }

    enum ExistingFileChoice { case merge, overwrite, abort }

    /// Interactive resolution for an existing config file. Prompts on stderr so
    /// a user piping stdout still sees the question; merge is the safe default.
    static func promptExistingChoice(configPath: String) -> ExistingFileChoice {
        var err = StandardError.shared
        print(
            "  \(configPath) already exists. [m]erge / [o]verwrite / [a]bort (default: merge): ",
            terminator: "", to: &err)
        switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "o", "overwrite": return .overwrite
        case "a", "abort", "q": return .abort
        default: return .merge
        }
    }
}
