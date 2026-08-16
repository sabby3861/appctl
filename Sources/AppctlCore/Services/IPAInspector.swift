import Foundation

public struct ArchiveMetadata: Sendable {
    public let bundleID: String
    public let shortVersion: String
    public let bundleVersion: String
    public init(bundleID: String, shortVersion: String, bundleVersion: String) {
        self.bundleID = bundleID
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
    }
}

/// Reads CFBundleIdentifier / CFBundleShortVersionString / CFBundleVersion from an
/// IPA's app Info.plist. The Build Upload API requires both version strings at
/// creation time, so we extract them rather than making users retype what's already
/// in the archive. Uses `unzip -p` on the exact member path — the plist alone is
/// extracted, never the archive.
public enum IPAInspector {

    public static func inspect(ipaAt url: URL) throws -> ArchiveMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppctlError.fileNotFound(path: url.path)
        }
        // List members first and select the top-level app's plist explicitly; a glob
        // handed to unzip could also match an embedded watch app's Info.plist.
        guard let listing = runZipTool(["-Z1", url.path]) else {
            throw AppctlError.invalidInput(
                field: "file", value: url.path, expected: "A readable zip archive (.ipa)")
        }
        let plistPaths = listing.split(separator: "\n").map(String.init)
            .filter { $0.range(of: #"^Payload/[^/]+\.app/Info\.plist$"#, options: .regularExpression) != nil }
        guard let plistPath = plistPaths.first else {
            throw AppctlError.invalidInput(
                field: "file", value: url.path,
                expected:
                    "An IPA containing Payload/<App>.app/Info.plist — for a .pkg or other archive, pass --short-version, --bundle-version, and --bundle-id explicitly"
            )
        }
        guard let plistData = runZipToolData(["-p", url.path, plistPath]),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let dict = plist as? [String: Any]
        else {
            throw AppctlError.invalidInput(
                field: "file", value: url.path, expected: "A parseable Info.plist inside the IPA")
        }
        guard let bundleID = dict["CFBundleIdentifier"] as? String,
            let shortVersion = dict["CFBundleShortVersionString"] as? String,
            let bundleVersion = dict["CFBundleVersion"] as? String
        else {
            throw AppctlError.missingRequiredField(
                field: "CFBundleIdentifier/CFBundleShortVersionString/CFBundleVersion",
                in: "\(plistPath) inside \(url.lastPathComponent)")
        }
        return ArchiveMetadata(bundleID: bundleID, shortVersion: shortVersion, bundleVersion: bundleVersion)
    }

    private static func runZipTool(_ arguments: [String]) -> String? {
        runZipToolData(arguments).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func runZipToolData(_ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
}
