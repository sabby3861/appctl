import Crypto
import Foundation
import Testing

@testable import AppctlCore

@Suite("TOML Parser") struct TOMLTests {
    @Test func parseBasic() {
        let r = ConfigLoader.parseTOML("[auth]\nkey_id = \"ABC\"")
        #expect(r["auth.key_id"] == "ABC")
    }
    @Test func parseComments() {
        let r = ConfigLoader.parseTOML("# comment\n[auth]\nkey = \"val\"")
        #expect(r["auth.key"] == "val")
        #expect(r.count == 1)
    }
    @Test func parseInlineComments() {
        let r = ConfigLoader.parseTOML("[auth]\ntimeout = 30 # seconds")
        #expect(r["auth.timeout"] == "30")
    }
    @Test func parseQuotedHash() {
        let r = ConfigLoader.parseTOML("[app]\nname = \"My #1 App\"")
        #expect(r["app.name"] == "My #1 App")
    }
    @Test func parseEmpty() { #expect(ConfigLoader.parseTOML("").isEmpty) }
    @Test func exampleConfigValid() {
        let p = ConfigLoader.parseTOML(ConfigLoader.exampleConfig())
        #expect(p["output.format"] == "text")
    }
    @Test func exampleConfigBoolKeysReachable() {
        // ConfigLoader.load() reads `output.verbose` and `output.no_color` from the
        // parsed map. If the example config stops emitting those keys, the
        // verbose/no_color paths in load() become silently unreachable.
        let p = ConfigLoader.parseTOML(ConfigLoader.exampleConfig())
        #expect(p["output.verbose"] == "false")
        #expect(p["output.no_color"] == "false")
        #expect(p["network.timeout"] == "30")
    }
}

@Suite("Path Resolution") struct PathResolutionTests {
    @Test func tildePathExpands() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = try ConfigLoader.load(privateKeyPathOverride: "~/x")
        #expect(config.privateKeyPath == "\(home)/x")
    }
    @Test func bareTildeExpands() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = try ConfigLoader.load(privateKeyPathOverride: "~")
        #expect(config.privateKeyPath == home)
    }
    @Test func midStringTildeUnchanged() throws {
        let config = try ConfigLoader.load(privateKeyPathOverride: "/a/b~c/d")
        #expect(config.privateKeyPath == "/a/b~c/d")
    }
    @Test func relativeTildeNotExpanded() throws {
        let config = try ConfigLoader.load(privateKeyPathOverride: "./~backup")
        let cwd = FileManager.default.currentDirectoryPath
        #expect(config.privateKeyPath == "\(cwd)/./~backup")
    }
}

@Suite("Errors") struct ErrorTests {
    @Test func allErrorsHaveMessages() {
        let errors: [AppctlError] = [
            .missingAPIKey(detail: "t"), .invalidKeyFile(path: "/t", reason: "t"), .jwtGenerationFailed(reason: "t"),
            .tokenExpired, .unauthorized(endpoint: "/t"), .configNotFound(searchPaths: ["/a"]),
            .requestFailed(url: "/t", statusCode: 400, body: nil), .rateLimited(retryAfter: 10),
            .timeout(url: "/t", duration: 30), .connectionFailed(host: "t", reason: "t"),
            .resourceNotFound(type: "App", identifier: "1"), .fileNotFound(path: "/t"),
            .certificateExpired(name: "t", expiryDate: Date()), .operationCancelled,
        ]
        for e in errors { #expect(!e.diagnosticMessage.isEmpty) }
    }
    @Test func httpFixSuggestions() {
        let e401 = AppctlError.requestFailed(url: "/t", statusCode: 401, body: nil)
        #expect(e401.diagnosticMessage.contains("auth verify"))
        let e500 = AppctlError.requestFailed(url: "/t", statusCode: 500, body: nil)
        #expect(e500.diagnosticMessage.contains("system-status"))
    }
}

@Suite("String Extensions") struct StringTests {
    @Test func truncate() {
        #expect("hello".truncated(to: 10) == "hello")
        #expect("hello world".truncated(to: 8) == "hello w…")
    }
    @Test func stateDisplay() {
        #expect("VALID".processingStateDisplay.contains("Valid"))
        #expect("READY_FOR_SALE".versionStateDisplay.contains("Ready for Sale"))
    }
}

@Suite("API Models") struct ModelTests {
    @Test func decodeApp() throws {
        let j = "{\"type\":\"apps\",\"id\":\"123\",\"attributes\":{\"name\":\"Test\",\"bundleId\":\"com.test\"}}".data(
            using: .utf8)!
        let app = try JSONDecoder().decode(App.self, from: j)
        #expect(app.id == "123")
        #expect(app.attributes?.name == "Test")
    }
    @Test func decodeBuild() throws {
        let j = "{\"type\":\"builds\",\"id\":\"b1\",\"attributes\":{\"version\":\"42\",\"processingState\":\"VALID\"}}"
            .data(using: .utf8)!
        let b = try JSONDecoder().decode(Build.self, from: j)
        #expect(b.attributes?.version == "42")
    }
    @Test func decodeListResponse() throws {
        let j =
            "{\"data\":[{\"type\":\"apps\",\"id\":\"1\"},{\"type\":\"apps\",\"id\":\"2\"}],\"links\":{\"next\":\"https://api.example.com?cursor=x\"},\"meta\":{\"paging\":{\"total\":5}}}"
            .data(using: .utf8)!
        let r = try JSONDecoder().decode(APIListResponse<App>.self, from: j)
        #expect(r.data.count == 2)
        #expect(r.meta?.paging?.total == 5)
        #expect(r.links?.next != nil)
    }
    @Test func decodeAPIError() throws {
        let j = "{\"errors\":[{\"status\":\"403\",\"code\":\"FORBIDDEN\",\"title\":\"Access denied\"}]}".data(
            using: .utf8)!
        let e = try JSONDecoder().decode(APIErrorResponse.self, from: j)
        #expect(e.errors[0].code == "FORBIDDEN")
    }

    @Test func decodeOptionalResponseWithData() throws {
        let j = "{\"data\":{\"type\":\"appStoreVersionSubmissions\",\"id\":\"sub-1\"}}".data(using: .utf8)!
        let r = try JSONDecoder().decode(OptionalAPIResponse<SubmissionResponse>.self, from: j)
        #expect(r.data?.id == "sub-1")
    }

    @Test func decodeOptionalResponseWithNull() throws {
        let j = "{\"data\":null,\"links\":{\"self\":\"https://api.example.com/x\"}}".data(using: .utf8)!
        let r = try JSONDecoder().decode(OptionalAPIResponse<SubmissionResponse>.self, from: j)
        #expect(r.data == nil)
    }
}

@Suite("Output") struct OutputTests {
    @Test func formatCases() {
        #expect(OutputFormat.allCases.count == 5)
        #expect(OutputFormat(rawValue: "json") == .json)
        #expect(OutputFormat(rawValue: "markdown") == .markdown)
        #expect(OutputFormat(rawValue: "xml") == nil)
    }
}

@Suite("Git Ref Validation") struct GitRefTests {
    @Test func acceptsCommonRefs() {
        let valid = [
            "HEAD", "HEAD~5", "HEAD^", "HEAD^^",
            "v1.0.0", "v1.2.3-rc.1", "release-1.0",
            "main", "develop", "feature/some-thing",
            "refs/tags/v1.0", "origin/main",
            "abc123def", "@",
        ]
        for ref in valid {
            #expect(AICommand.ReleaseNotes.isValidGitRef(ref), "expected \(ref) to be accepted")
        }
    }

    @Test func rejectsInjectionAttempts() {
        let invalid = [
            "",
            "-HEAD",
            "--upload-pack=evil",
            "HEAD; rm -rf ~",
            "HEAD && echo pwned",
            "HEAD | cat /etc/passwd",
            "HEAD$(whoami)",
            "HEAD`id`",
            "HEAD\nrm -rf",
            "HEAD\trm",
            "HEAD with space",
            "HEAD'quote",
            "HEAD\"quote",
            "HEAD#comment",
        ]
        for ref in invalid {
            #expect(!AICommand.ReleaseNotes.isValidGitRef(ref), "expected \(ref.debugDescription) to be rejected")
        }
    }
}

@Suite("Crash-path validation") struct CrashPathTests {
    // String.prefix(_:) traps on negative arguments and Int multiplication traps on
    // overflow. These validators sit in front of the `run()` paths that would otherwise
    // feed user-supplied numbers into those traps.

    @Test func releaseNotesAcceptsReasonableMaxLength() throws {
        try AICommand.ReleaseNotes.validate(maxLength: 4000)
        try AICommand.ReleaseNotes.validate(maxLength: 4)
    }

    @Test func releaseNotesRejectsTinyMaxLength() {
        for bad in [Int.min, -1, 0, 1, 2, 3] {
            #expect(throws: AppctlError.self) {
                try AICommand.ReleaseNotes.validate(maxLength: bad)
            }
        }
    }

    @Test func watchAcceptsSaneRange() throws {
        try WorkflowCommand.Watch.validate(interval: 1, timeout: 1)
        try WorkflowCommand.Watch.validate(interval: 30, timeout: 120)
        try WorkflowCommand.Watch.validate(interval: 30, timeout: 1440)
    }

    @Test func watchRejectsZeroOrNegativeInterval() {
        for bad in [Int.min, -1, 0] {
            #expect(throws: AppctlError.self) {
                try WorkflowCommand.Watch.validate(interval: bad, timeout: 60)
            }
        }
    }

    @Test func watchRejectsOverflowingTimeout() {
        for bad in [0, -1, 1441, Int.max] {
            #expect(throws: AppctlError.self) {
                try WorkflowCommand.Watch.validate(interval: 30, timeout: bad)
            }
        }
    }
}

@Suite("RetryStrategy") struct RetryTests {
    /// Pin jitter to its minimum so the exponential ladder is exact:
    /// exp/2 + 0 = base × 2^attempt / 2.
    private let noJitter: (ClosedRange<Double>) -> Double = { $0.lowerBound }
    /// Pin jitter to its maximum: exp/2 + exp/2 = the full exponential value.
    private let maxJitter: (ClosedRange<Double>) -> Double = { $0.upperBound }

    @Test func backoffDoublesEachAttempt() {
        for (attempt, expected) in [(0, 1.0), (1, 2.0), (2, 4.0), (3, 8.0)] {
            #expect(
                RetryStrategy.delay(for: .rateLimited, attempt: attempt, base: 1.0, random: maxJitter)
                    == .seconds(expected))
        }
    }

    @Test func jitterSpansHalfTheExponential() {
        // Equal jitter: the delay lands in [exp/2, exp], never below half the backoff.
        #expect(
            RetryStrategy.delay(for: .serverError, attempt: 2, base: 1.0, random: noJitter)
                == .seconds(2.0))
        #expect(
            RetryStrategy.delay(for: .serverError, attempt: 2, base: 1.0, random: maxJitter)
                == .seconds(4.0))
    }

    @Test func delayNeverExceedsCap() {
        // Attempt 30 with base 1 would be 2^30 seconds without the cap.
        #expect(
            RetryStrategy.delay(for: .rateLimited, attempt: 30, base: 1.0, random: maxJitter)
                == .seconds(RetryStrategy.delayCap))
    }

    @Test func retryAfterIsHonoredVerbatimWithinTheCap() {
        // Server-directed waits take precedence over the exponential and get no jitter.
        #expect(
            RetryStrategy.delay(for: .rateLimited, attempt: 0, retryAfter: 15, random: maxJitter)
                == .seconds(15.0))
    }

    @Test func retryAfterClampsAboveMaximum() {
        // A hostile or buggy server could send a huge Retry-After. We must not honor it
        // beyond the cap.
        #expect(
            RetryStrategy.delay(for: .rateLimited, attempt: 0, retryAfter: 999_999)
                == .seconds(RetryStrategy.delayCap))
    }

    @Test func retryAfterClampsBelowZero() {
        // Negative values would be interpreted as Task.sleep(for: .seconds(-1)),
        // which traps. Always clamp to non-negative.
        #expect(
            RetryStrategy.delay(for: .rateLimited, attempt: 0, retryAfter: -5) == .seconds(0.0))
    }

    @Test func attemptBudgetsPerCategory() {
        #expect(RetryStrategy.rateLimited.maxAttempts == 5)
        #expect(RetryStrategy.serverError.maxAttempts == 3)
        #expect(RetryStrategy.transport.maxAttempts == 3)
    }
}

@Suite("JWT generation + caching") struct JWTTests {
    /// Build a valid PKCS#8 PEM for a freshly generated P-256 key.
    private static func freshPEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    @Test func generatesValidJWTStructure() async throws {
        let gen = try JWTGenerator(keyID: "TEST", issuerID: "issuer-1", privateKeyPEM: Self.freshPEM())
        let token = try await gen.token()
        let parts = token.split(separator: ".")
        #expect(parts.count == 3, "JWT must have header.payload.signature")
        for part in parts { #expect(!part.isEmpty) }
    }

    @Test func cachesTokenWithinTTL() async throws {
        let gen = try JWTGenerator(keyID: "TEST", issuerID: "issuer-1", privateKeyPEM: Self.freshPEM())
        let first = try await gen.token()
        let second = try await gen.token()
        #expect(first == second, "Subsequent calls within the TTL must return the cached token")
    }

    @Test func rejectsMalformedPEM() {
        #expect(throws: AppctlError.self) {
            _ = try JWTGenerator(keyID: "T", issuerID: "I", privateKeyPEM: "not a pem")
        }
    }
}

@Suite("Plugin discovery") struct PluginDiscoveryTests {
    private static func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "appctl-plugin-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeExecutable(at path: String, contents: String = "#!/bin/sh\nexit 0\n") throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: path)
    }

    @Test func findsExecutablesPrefixedAppctlDash() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Self.writeExecutable(at: "\(dir)/appctl-foo")
        try Self.writeExecutable(at: "\(dir)/appctl-bar")

        let plugins = PluginManager.discover(in: [dir])
        #expect(plugins.map(\.name) == ["bar", "foo"], "Should be sorted alphabetically by stripped name")
    }

    @Test func skipsNonAppctlPrefixed() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Self.writeExecutable(at: "\(dir)/notappctl")
        try Self.writeExecutable(at: "\(dir)/appctl-real")

        let plugins = PluginManager.discover(in: [dir])
        #expect(plugins.map(\.name) == ["real"])
    }

    @Test func skipsNonExecutableFiles() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "data".write(toFile: "\(dir)/appctl-readme", atomically: true, encoding: .utf8)
        // Permissions default to 0644 — not executable; should be filtered out.
        try Self.writeExecutable(at: "\(dir)/appctl-tool")

        let plugins = PluginManager.discover(in: [dir])
        #expect(plugins.map(\.name) == ["tool"])
    }

    @Test func deduplicatesAcrossDirs() throws {
        let first = try Self.makeTempDir()
        let second = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        try Self.writeExecutable(at: "\(first)/appctl-thing")
        try Self.writeExecutable(at: "\(second)/appctl-thing")

        let plugins = PluginManager.discover(in: [first, second])
        #expect(plugins.count == 1, "First match wins; later duplicates skipped")
        #expect(plugins.first?.path == "\(first)/appctl-thing")
    }

    @Test func ignoresUnreadableDirs() {
        // Pointing at a path that doesn't exist or isn't a directory must not throw.
        let plugins = PluginManager.discover(in: ["/this/path/does/not/exist/anywhere"])
        #expect(plugins.isEmpty)
    }
}

@Suite("Certificate expiry predicate") struct CertExpiryTests {
    private static func cert(expirationDate: String?) -> Certificate {
        Certificate(
            type: "certificates",
            id: "x",
            attributes: CertificateAttributes(
                name: nil, certificateType: nil, displayName: nil,
                serialNumber: nil, platform: nil, expirationDate: expirationDate))
    }

    @Test func nilExpirationIsNotExpiringSoon() {
        #expect(!CertificatesCommand.List.isExpiringSoon(Self.cert(expirationDate: nil)))
    }

    @Test func alreadyExpiredIsNotExpiringSoon() {
        // We surface "already expired" as its own state via expiryDisplay; the
        // expiring-soon predicate only flags positive day counts within the window.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let yesterday = Date().addingTimeInterval(-86_400)
        #expect(
            !CertificatesCommand.List.isExpiringSoon(Self.cert(expirationDate: formatter.string(from: yesterday))))
    }

    @Test func withinWindowIsExpiringSoon() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let inTenDays = Date().addingTimeInterval(10 * 86_400)
        #expect(
            CertificatesCommand.List.isExpiringSoon(Self.cert(expirationDate: formatter.string(from: inTenDays))))
    }

    @Test func farFutureIsNotExpiringSoon() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let inOneYear = Date().addingTimeInterval(365 * 86_400)
        #expect(
            !CertificatesCommand.List.isExpiringSoon(Self.cert(expirationDate: formatter.string(from: inOneYear))))
    }
}
