import Foundation

/// Turns a thrown error into the process's final output and exit code, routing
/// through the stable error taxonomy (docs/errors.md). Lives in AppctlCore so the
/// argv scan and rendering are unit-testable; the CLI's `main()` is a thin caller.
public enum FailureRenderer {
    /// Best-effort detection of the output mode before (or after a failed)
    /// ArgumentParser parse — at `main()`'s catch site no command exists, so the
    /// parsed `GlobalOptions` are out of reach and argv is all there is.
    ///
    /// Rules: `--output x` / `--format x` / `--output=x` / `--format=x`;
    /// the last occurrence wins (matching ArgumentParser); tokens after a bare
    /// `--` terminator are positionals and ignored; an unrecognized value reads
    /// as "no mode", never as a guess.
    public static func earlyOutputMode(from arguments: [String]) -> OutputFormat? {
        var mode: OutputFormat?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" { break }
            for flag in ["--output", "--format"] {
                if token == flag {
                    mode = index + 1 < arguments.count ? OutputFormat(rawValue: arguments[index + 1]) : nil
                } else if token.hasPrefix(flag + "=") {
                    mode = OutputFormat(rawValue: String(token.dropFirst(flag.count + 1)))
                }
            }
            index += 1
        }
        return mode
    }

    /// Whether the failure should emit a JSON envelope on stdout — mirroring the
    /// success path's resolution: an explicit flag wins; `--query` implies JSON;
    /// otherwise piped/CI output defaults to JSON. Environment probes are
    /// injectable so the heuristic branches are testable.
    static func wantsJSONEnvelope(
        arguments: [String],
        isTerminal: () -> Bool = ConfigLoader.isTerminal,
        isCI: () -> Bool = ConfigLoader.isCI
    ) -> Bool {
        if let mode = earlyOutputMode(from: arguments) { return mode == .json }
        for token in arguments {
            if token == "--" { break }
            if token == "--query" || token.hasPrefix("--query=") { return true }
        }
        return !isTerminal() || isCI()
    }

    /// Renders a failure and returns the exit code the process should use, or nil
    /// when the error is not appctl's to render (help requests, clean exits,
    /// explicit `ExitCode` throws) — the caller falls back to ArgumentParser.
    ///
    /// - Parameters:
    ///   - isUsageError: true when ArgumentParser classified the error as a
    ///     parse/validation failure (its EX_USAGE), remapped into exit class 1.
    ///   - usageMessage: ArgumentParser's full message including usage text.
    public static func render(
        _ error: Error, arguments: [String], isUsageError: Bool, usageMessage: String
    ) -> Int32? {
        var stderr = StandardError.shared
        if let appctlError = error as? AppctlError {
            if wantsJSONEnvelope(arguments: arguments) {
                // stdout carries the machine-readable envelope; the human text
                // still goes to stderr so interactive pipes show both.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                if let payload = try? encoder.encode(Envelope.failure(appctlError)) {
                    print(String(decoding: payload, as: UTF8.self))
                }
            }
            print(appctlError.diagnosticMessage, to: &stderr)
            return appctlError.errorCode.exitClass
        }
        if isUsageError {
            print(usageMessage, to: &stderr)
            return 1
        }
        return nil
    }
}
