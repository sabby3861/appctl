import Foundation

/// Runs an executable streaming its stdout+stderr line by line. A seam so tests can
/// exercise the altool flow without spawning processes.
public protocol ProcessRunner: Sendable {
    /// Returns the process exit code; `onOutputLine` receives merged stdout/stderr lines.
    func run(
        executable: String, arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

/// Real subprocess execution. Output is consumed via `FileHandle.bytes.lines`, so
/// lines stream to the caller as altool produces them.
public struct SubprocessRunner: ProcessRunner {
    public init() {}

    public func run(
        executable: String, arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AppctlError.subprocessFailed(command: executable, exitCode: -1)
        }
        for try await line in pipe.fileHandleForReading.bytes.lines {
            onOutputLine(line)
        }
        // The loop ends at pipe EOF, so the process has closed its output and exit is
        // imminent — the same brief blocking wait EnvironmentDiagnostics.shell uses.
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The `xcrun altool --upload-package` backend. altool locates .p8 keys only in its
/// own well-known directories — never appctl's configured key path — so availability
/// of the key is preflighted with an actionable error instead of a cryptic altool one.
public enum AltoolBackend {

    public static let keySearchDirs = [
        "./private_keys", "~/private_keys", "~/.private_keys", "~/.appstoreconnect/private_keys",
    ]

    /// altool's `--type` vocabulary for our `--platform` values.
    public static func altoolType(forPlatform platform: String) -> String? {
        switch platform.lowercased() {
        case "ios": return "ios"
        case "macos": return "macos"
        case "tvos": return "appletvos"
        case "visionos": return "visionos"
        default: return nil
        }
    }

    /// Pure invocation builder so `--dry-run` output and tests share the exact argv.
    public static func invocation(
        file: String, altoolType: String, appleID: String, bundleID: String,
        shortVersion: String, bundleVersion: String, keyID: String, issuerID: String
    ) -> [String] {
        [
            "xcrun", "altool", "--upload-package", file,
            "--type", altoolType,
            "--apple-id", appleID,
            "--bundle-id", bundleID,
            "--bundle-short-version-string", shortVersion,
            "--bundle-version", bundleVersion,
            "--apiKey", keyID,
            "--apiIssuer", issuerID,
        ]
    }

    public static func keyFileExists(keyID: String) -> Bool {
        keySearchDirs.contains { dir in
            let expanded = NSString(string: dir).expandingTildeInPath
            return FileManager.default.fileExists(atPath: "\(expanded)/AuthKey_\(keyID).p8")
        }
    }

    /// Runs the invocation, streaming altool's output to stderr as it arrives.
    /// A non-zero exit surfaces as a What/Why/Fix error after the streamed output.
    public static func run(
        invocation: [String], runner: any ProcessRunner, output: OutputFormatter
    ) async throws {
        let exitCode = try await runner.run(
            executable: "/usr/bin/xcrun", arguments: Array(invocation.dropFirst()),
            onOutputLine: { line in
                var s = StandardError.shared
                print("  \(line)", to: &s)
            })
        guard exitCode == 0 else {
            throw AppctlError.subprocessFailed(
                command: invocation.joined(separator: " "), exitCode: exitCode)
        }
    }
}
