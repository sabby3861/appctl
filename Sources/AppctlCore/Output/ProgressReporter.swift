import Foundation

public struct UploadProgress: Sendable {
    public let completedParts: Int
    public let totalParts: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(completedParts: Int, totalParts: Int, completedBytes: Int64, totalBytes: Int64) {
        self.completedParts = completedParts
        self.totalParts = totalParts
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var percent: Int {
        totalBytes > 0 ? Int((Double(completedBytes) / Double(totalBytes)) * 100) : 0
    }
}

/// Upload progress on stderr: an in-place bar (bytes + parts) on a TTY, plain
/// percentage lines otherwise, and nothing at all in JSON mode (matching
/// `OutputFormatter`'s quiet-stderr contract for piped consumers).
public struct ProgressReporter: Sendable {
    private let silent: Bool
    private let isTTY: Bool
    private let useColor: Bool

    public init(output: OutputFormatter) {
        self.silent = output.format == .json
        self.isTTY = isatty(STDERR_FILENO) == 1
        self.useColor = output.useColor
    }

    public func report(_ p: UploadProgress) {
        guard !silent else { return }
        var s = StandardError.shared
        let bytes = Self.byteSummary(p)
        if isTTY {
            let width = 24
            let filled = p.totalBytes > 0 ? Int(Double(width) * Double(p.completedBytes) / Double(p.totalBytes)) : 0
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
            let line = "  [\(bar)] \(p.percent)% — \(p.completedParts)/\(p.totalParts) parts, \(bytes)"
            print("\r\(useColor ? "\u{001B}[36m\(line)\u{001B}[0m" : line)", terminator: "", to: &s)
        } else {
            print("Uploaded \(p.completedParts)/\(p.totalParts) parts (\(p.percent)%, \(bytes))", to: &s)
        }
    }

    /// Ends the in-place TTY line so subsequent output starts on a fresh line.
    public func finish() {
        guard !silent, isTTY else { return }
        var s = StandardError.shared
        print("", to: &s)
    }

    private static func byteSummary(_ p: UploadProgress) -> String {
        let done = ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file)
        return "\(done) / \(total)"
    }
}
