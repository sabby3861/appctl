import ArgumentParser
import Foundation

public struct AICommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Authoring helpers (no LLM calls).",
        discussion: """
            These commands run locally and do not call any external AI service.
              release-notes  Categorize git commit subjects into a What's New / Bug Fixes summary.
              optimize       Print an ASO checklist with simple length warnings.
              translate      Scaffold metadata/<locale>/ directories for the listed locales.
            """,
        subcommands: [ReleaseNotes.self, Optimize.self, Translate.self]
    )
    public init() {}

    struct ReleaseNotes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "release-notes",
            abstract: "Categorize git commit subjects into a release-notes draft."
        )
        @Option(name: .long, help: "Start ref.") var since: String = "HEAD~20"
        @Option(name: .long, help: "End ref.") var until: String = "HEAD"
        @Option(name: .long, help: "Max length.") var maxLength: Int = 4000
        @Option(name: .long, help: "Tone: casual, professional, minimal.") var tone: String = "professional"
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let output = try globals.outputFormatter()
            try Self.validate(maxLength: maxLength)
            guard Self.isValidGitRef(since) else {
                throw AppctlError.invalidInput(
                    field: "--since",
                    value: since,
                    expected: "A git ref (letters, digits, and ./_-~^@/, no leading dash)"
                )
            }
            guard Self.isValidGitRef(until) else {
                throw AppctlError.invalidInput(
                    field: "--until",
                    value: until,
                    expected: "A git ref (letters, digits, and ./_-~^@/, no leading dash)"
                )
            }
            let spinner = output.startSpinner("Reading git history")
            guard let gitLog = Self.runGitLog(since: since, until: until) else {
                spinner.stop(success: false)
                throw AppctlError.unsupportedOperation(
                    name: "ai release-notes",
                    reason: "Could not read git log. Run inside a git repository with git on PATH."
                )
            }
            spinner.stop()
            let commits =
                gitLog
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !commits.isEmpty else {
                output.warning("No commits found between \(since) and \(until)")
                return
            }
            output.info("Found \(commits.count) commits")
            var features: [String] = []
            var fixes: [String] = []
            var improvements: [String] = []
            for c in commits {
                let l = c.lowercased()
                let cleaned = cleanCommit(c)
                if l.hasPrefix("feat") || l.contains("add ") || l.contains("new ") {
                    features.append(cleaned)
                } else if l.hasPrefix("fix") || l.contains("bug") || l.contains("crash") {
                    fixes.append(cleaned)
                } else {
                    improvements.append(cleaned)
                }
            }
            var notes: String
            switch tone {
            case "casual":
                var lines: [String] = []
                if !features.isEmpty {
                    lines.append("🆕 New:")
                    lines.append(contentsOf: features.prefix(5).map { "  - \($0)" })
                }
                if !fixes.isEmpty {
                    lines.append("\n🐛 Fixed:")
                    lines.append(contentsOf: fixes.prefix(3).map { "  - \($0)" })
                }
                notes = lines.joined(separator: "\n")
            case "minimal":
                let all = Array(features.prefix(3)) + Array(fixes.prefix(2)) + Array(improvements.prefix(2))
                notes = all.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            default:
                var sections: [String] = []
                if !features.isEmpty {
                    sections.append("What's New\n\(features.prefix(5).map { "• \($0)" }.joined(separator: "\n"))")
                }
                if !fixes.isEmpty {
                    sections.append("Bug Fixes\n\(fixes.prefix(3).map { "• \($0)" }.joined(separator: "\n"))")
                }
                notes = sections.joined(separator: "\n\n")
            }
            if notes.count > maxLength { notes = String(notes.prefix(maxLength - 3)) + "..." }
            output.info("Generated (\(notes.count)/\(maxLength) chars):")
            output.info("─────────────────")
            print(notes)
        }

        private func cleanCommit(_ msg: String) -> String {
            var c = msg
            for p in ["feat:", "fix:", "chore:", "build:", "ci:", "perf:", "docs:", "style:", "refactor:", "test:"] {
                if c.lowercased().hasPrefix(p) { c = String(c.dropFirst(p.count)) }
            }
            if c.first == "(", let close = c.firstIndex(of: ")") { c = String(c[c.index(after: close)...]) }
            c = c.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if let f = c.first { c = f.uppercased() + c.dropFirst() }
            return c
        }

        /// Reject sizes too small to fit even the truncation marker; the underlying
        /// `String.prefix(_:)` traps on negative arguments.
        static func validate(maxLength: Int) throws {
            guard maxLength > 3 else {
                throw AppctlError.invalidInput(
                    field: "--max-length",
                    value: String(maxLength),
                    expected: "Greater than 3 (need room for the truncation marker)"
                )
            }
        }

        static func isValidGitRef(_ ref: String) -> Bool {
            guard !ref.isEmpty, !ref.hasPrefix("-") else { return false }
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-~^@"
            )
            return ref.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        static func runGitLog(since: String, until: String) -> String? {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [
                "git", "log", "\(since)..\(until)",
                "--pretty=format:%s", "--no-merges", "--",
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            // Drain the pipe before waitUntilExit; reading after a long-running
            // process exits risks deadlock if its output exceeds the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    struct Optimize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print an ASO checklist with name-length warnings.")
        @Option(name: .long, help: "App ID.") var appId: String?
        @OptionGroup var globals: GlobalOptions
        init() {}
        func run() async throws {
            let (client, config) = try globals.apiClient()
            let output = try globals.outputFormatter()
            let id = try resolveAppID(appId, config: config)
            let spinner = output.startSpinner("Analyzing metadata")
            let r: APIResponse<App> = try await client.get(
                "apps/\(id)", queryItems: [URLQueryItem(name: "fields[apps]", value: "name,bundleId,primaryLocale")])
            spinner.stop()
            let name = r.data.attributes?.name ?? "Unknown"
            output.printDetail(fields: [
                ("App:", name), ("Bundle ID:", r.data.attributes?.bundleId ?? "—"),
                ("Locale:", r.data.attributes?.primaryLocale ?? "—"),
            ])
            output.info("\nRecommendations:")
            output.info("  1. App name ≤30 chars (yours: \(name.count))\(name.count > 30 ? " ⚠ Too long!" : " ✅")")
            output.info("  2. Use all 100 keyword characters")
            output.info("  3. Don't repeat app name words in keywords")
            output.info("  4. Use singular forms (Apple matches both)")
        }
    }

    struct Translate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scaffold metadata/<locale>/ folders for listed locales.")
        @Option(name: .long, help: "Source text.") var text: String
        @Option(name: .long, help: "Target locales (comma-separated).") var locales: String
        @OptionGroup var globals: GlobalOptions
        init() {}

        // English locale chosen so language names render the same regardless of who runs the tool.
        private static let displayLocale = Locale(identifier: "en_US")

        func run() async throws {
            let output = try globals.outputFormatter()
            let targets = locales.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            output.info("Translation scaffolding for \(targets.count) locales")
            for locale in targets {
                let name = Self.displayLocale.localizedString(forIdentifier: locale) ?? locale
                output.info("  [\(locale)] \(name) — file: metadata/\(locale)/description.txt")
            }
            output.info("\nmkdir -p metadata/{\(targets.joined(separator: ","))}")
        }
    }
}
