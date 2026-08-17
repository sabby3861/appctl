import Foundation

/// Every error in appctl follows a three-part pattern:
/// 1. What went wrong
/// 2. Why it happened
/// 3. How to fix it
public enum AppctlError: LocalizedError, CustomStringConvertible {

    case missingAPIKey(detail: String)
    /// The developer account has an unsigned agreement blocking API access
    /// (Apple reports it as a FORBIDDEN error mentioning the agreement).
    case agreementPending(detail: String)
    case invalidKeyFile(path: String, reason: String)
    case jwtGenerationFailed(reason: String)
    case tokenExpired
    case unauthorized(endpoint: String)
    case configNotFound(searchPaths: [String])
    case configParseError(path: String, line: Int?, reason: String)
    case missingRequiredField(field: String, in: String)
    case requestFailed(url: String, statusCode: Int, body: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout(url: String, duration: TimeInterval)
    case connectionFailed(host: String, reason: String)
    case invalidResponse(url: String, reason: String)
    case apiError(operation: String, statusCode: Int, errors: [APIErrorDetail])
    case resourceNotFound(type: String, identifier: String)
    case conflictError(resource: String, detail: String)
    /// A batch operation completed for some items and failed for others.
    case partialFailure(operation: String, failed: [String])
    case fileNotFound(path: String)
    case fileNotReadable(path: String)
    case fileWriteError(path: String, reason: String)
    case certificateExpired(name: String, expiryDate: Date)
    case certificateNotFound(serialNumber: String?)
    case profileMismatch(bundleID: String, profileBundleID: String)
    case signingIdentityNotFound(name: String)
    case invalidInput(field: String, value: String, expected: String)
    case charLimitExceeded(field: String, limit: Int, actual: Int)
    case operationCancelled
    case unsupportedOperation(name: String, reason: String)
    case keychainError(operation: String, service: String, status: OSStatus, reason: String)
    case subprocessFailed(command: String, exitCode: Int32)
    case altoolKeyNotFound(keyID: String, searchedDirs: [String])
    case buildProcessingFailed(state: String, details: [String])
    case uploadPartFailed(partNumber: Int64, attempts: Int, reason: String)
    case screenshotValidationFailed(failures: [String])
    case confirmationRequired(operation: String)
    case schemaUnavailable(reason: String)

    public var description: String { diagnosticMessage }
    public var errorDescription: String? { diagnosticMessage }

    /// What/Why/Fix text plus the stable code and its docs anchor. A user cancel
    /// carries no code line — there is nothing to look up.
    public var diagnosticMessage: String {
        if case .operationCancelled = self { return baseMessage }
        let code = errorCode
        return baseMessage + "\n  Code: \(code.rawValue) — \(code.docsURL)"
    }

    private var baseMessage: String {
        switch self {
        case .missingAPIKey(let detail):
            return
                "✗ Missing API Key\n  \(detail)\n  Fix: Run `appctl auth setup` or set APPCTL_KEY_ID, APPCTL_ISSUER_ID, and APPCTL_PRIVATE_KEY_PATH environment variables."
        case .agreementPending(let detail):
            return
                "✗ Developer Agreement Pending\n  \(detail)\n  Fix: An Account Holder must accept the latest agreement in App Store Connect → Business (or Agreements, Tax, and Banking), then retry."
        case .invalidKeyFile(let path, let reason):
            return
                "✗ Invalid API Key File\n  Path: \(path)\n  Reason: \(reason)\n  Fix: Download a fresh .p8 key file from App Store Connect → Users and Access → Keys."
        case .jwtGenerationFailed(let reason):
            return
                "✗ JWT Token Generation Failed\n  \(reason)\n  Fix: Verify your .p8 key file is valid and not corrupted."
        case .tokenExpired:
            return "✗ API Token Expired\n  Fix: appctl will auto-refresh. If this persists, run `appctl auth verify`."
        case .unauthorized(let endpoint):
            return
                "✗ Unauthorized Access\n  Endpoint: \(endpoint)\n  Fix: Verify your API key has the required role in App Store Connect → Users and Access → Keys."
        case .configNotFound(let paths):
            let searched = paths.map { "  • \($0)" }.joined(separator: "\n")
            return
                "✗ Configuration Not Found\n  Searched:\n\(searched)\n  Fix: Run `appctl init` to create a configuration file."
        case .configParseError(let path, let line, let reason):
            let lineInfo = line.map { " (line \($0))" } ?? ""
            return
                "✗ Configuration Parse Error\n  File: \(path)\(lineInfo)\n  \(reason)\n  Fix: Check the TOML syntax. Run `appctl init --example` for a valid template."
        case .missingRequiredField(let field, let context):
            return
                "✗ Missing Required Field\n  Field \"\(field)\" is required in \(context).\n  Fix: Add the field to your .appctl.toml or pass it via --\(field) flag."
        case .requestFailed(let url, let statusCode, let body):
            let bodySnippet = body.map { "\n  Response: \(String($0.prefix(200)))" } ?? ""
            return
                "✗ API Request Failed\n  URL: \(url)\n  Status: \(statusCode)\(bodySnippet)\n  Fix: \(Self.httpStatusFix(statusCode))"
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { "Wait \(Int($0)) seconds." } ?? "Wait a moment."
            return "✗ Rate Limited\n  Fix: \(wait) Consider batching operations."
        case .timeout(let url, let duration):
            return
                "✗ Request Timed Out\n  URL: \(url)\n  Duration: \(String(format: "%.1f", duration))s\n  Fix: Check your network. See https://developer.apple.com/system-status/"
        case .connectionFailed(let host, let reason):
            return
                "✗ Connection Failed\n  Host: \(host)\n  \(reason)\n  Fix: Check your internet connection and firewall settings."
        case .invalidResponse(let url, let reason):
            return
                "✗ Invalid API Response\n  URL: \(url)\n  \(reason)\n  Fix: Check for appctl updates: `appctl update`"
        case .apiError(let operation, let statusCode, let errors):
            var lines = [
                "✗ App Store Connect Error",
                "  Operation: \(operation)",
                "  Status: HTTP \(statusCode)",
            ]
            for e in errors {
                lines.append("  \(e.code): \(e.title)\(e.detail.map { " — \($0)" } ?? "")")
            }
            if let fix = Self.apiErrorFix(codes: errors.map(\.code)) {
                lines.append("  Fix: \(fix)")
            }
            return lines.joined(separator: "\n")
        case .resourceNotFound(let type, let identifier):
            return
                "✗ \(type) Not Found\n  Identifier: \(identifier)\n  Fix: Verify it exists. Run `appctl \(type.lowercased())s list` to see available items."
        case .conflictError(let resource, let detail):
            return "✗ Conflict\n  \(resource): \(detail)\n  Fix: Another operation may be in progress. Wait and retry."
        case .partialFailure(let operation, let failed):
            let items = failed.map { "  • \($0)" }.joined(separator: "\n")
            return
                "✗ Partial Failure\n  \(operation) failed for:\n\(items)\n  Fix: The warnings above show each cause. Fix them and re-run — completed items are safe to repeat."
        case .fileNotFound(let path):
            return "✗ File Not Found\n  Path: \(path)"
        case .fileNotReadable(let path):
            return "✗ File Not Readable\n  Path: \(path)\n  Fix: Check permissions. Run: chmod +r \(path)"
        case .fileWriteError(let path, let reason):
            return "✗ Cannot Write File\n  Path: \(path)\n  \(reason)"
        case .certificateExpired(let name, let expiryDate):
            let f = DateFormatter()
            f.dateStyle = .medium
            return
                "✗ Certificate Expired\n  Name: \(name)\n  Expired: \(f.string(from: expiryDate))\n  Fix: Run `appctl certificates create --type distribution`."
        case .certificateNotFound(let serial):
            let info = serial.map { " (serial: \($0))" } ?? ""
            return "✗ Certificate Not Found\(info)\n  Fix: Run `appctl certificates list`."
        case .profileMismatch(let bundleID, let profileBundleID):
            return
                "✗ Provisioning Profile Mismatch\n  App Bundle ID: \(bundleID)\n  Profile Bundle ID: \(profileBundleID)"
        case .signingIdentityNotFound(let name):
            return "✗ Signing Identity Not Found\n  Identity: \(name)\n  Fix: Install the certificate in your Keychain."
        case .invalidInput(let field, let value, let expected):
            return "✗ Invalid Input\n  Field: \(field)\n  Value: \"\(value)\"\n  Expected: \(expected)"
        case .charLimitExceeded(let field, let limit, let actual):
            return
                "✗ Character Limit Exceeded\n  Field: \(field)\n  Length: \(actual) characters (limit \(limit))\n  Fix: Shorten the text by \(actual - limit) character\(actual - limit == 1 ? "" : "s") and re-run. Nothing was pushed."
        case .operationCancelled:
            return "Operation cancelled."
        case .unsupportedOperation(let name, let reason):
            return "✗ Unsupported Operation\n  \(name): \(reason)"
        case .keychainError(let operation, let service, let status, let reason):
            return
                "✗ Keychain \(operation.capitalized) Failed\n  Service: \(service)\n  Reason: \(reason) (OSStatus \(status))\n  Fix: Unlock your login keychain and retry. Inspect items in Keychain Access by searching \"\(service)\"."
        case .subprocessFailed(let command, let exitCode):
            return
                "✗ Command Failed\n  Command: \(command)\n  Exit code: \(exitCode)\n  Fix: The tool's output above explains the failure. Re-run with --verbose for the full invocation."
        case .altoolKeyNotFound(let keyID, let searchedDirs):
            let dirs = searchedDirs.map { "  • \($0)" }.joined(separator: "\n")
            return
                "✗ altool Cannot Find Your API Key\n  altool only reads keys from its own directories, not appctl's configured path. Searched:\n\(dirs)\n  Fix: Copy your key: mkdir -p ~/.appstoreconnect/private_keys && cp <your-key.p8> ~/.appstoreconnect/private_keys/AuthKey_\(keyID).p8"
        case .buildProcessingFailed(let state, let details):
            let detail = details.isEmpty ? "" : "\n" + details.map { "  • \($0)" }.joined(separator: "\n")
            return
                "✗ Build Processing Failed\n  State: \(state)\(detail)\n  Fix: Check the build in App Store Connect → TestFlight for the full processing report, correct the issue, and upload a new build."
        case .uploadPartFailed(let partNumber, let attempts, let reason):
            return
                "✗ Upload Part Failed\n  Part \(partNumber) failed after \(attempts) attempt(s): \(reason)\n  Fix: Re-run the same command — completed parts are recorded in the sidecar file and only missing parts will be re-uploaded."
        case .screenshotValidationFailed(let failures):
            let failureLines = failures.map { "  • \($0)" }.joined(separator: "\n")
            let accepted = ScreenshotDimensions.acceptedSizesLines()
                .map { "    \($0)" }.joined(separator: "\n")
            return
                "✗ Screenshot Validation Failed\n\(failureLines)\n  Accepted sizes:\n\(accepted)\n  Fix: Resize or re-export the files above, then re-run. Nothing was uploaded."
        case .confirmationRequired(let operation):
            return
                "✗ Confirmation Required\n  \(operation) is destructive and cannot be undone.\n  Fix: Re-run the same command with --confirm to proceed."
        case .schemaUnavailable(let reason):
            return
                "✗ API Schema Unavailable\n  \(reason)\n  Fix: Check your network connection and retry, or refresh the cached copy with `appctl api --update-schema`."
        }
    }

    /// Fix hints are keyed off Apple's error codes only — never the HTTP status —
    /// so an unrecognized failure (e.g. a 404 from a removed endpoint) is reported
    /// as-is instead of being misdiagnosed with an unrelated hint.
    private static func apiErrorFix(codes: [String]) -> String? {
        if codes.contains(where: { $0.hasPrefix("ENTITY_ERROR") }) {
            return
                "Complete the version's required metadata in App Store Connect (description, screenshots, privacy policy, …), then retry."
        }
        if codes.contains(where: { $0.hasPrefix("STATE_ERROR") }) {
            return
                "A review submission may already be open for this app. Cancel it or wait for it to finish, then retry."
        }
        return nil
    }

    private static func httpStatusFix(_ code: Int) -> String {
        switch code {
        case 401: return "Run `appctl auth verify` to check your credentials."
        case 403: return "Your API key may lack permissions. Check key roles in App Store Connect."
        case 404: return "The requested resource doesn't exist. Verify the identifier."
        case 429: return "Rate limited. Wait and retry with fewer concurrent requests."
        case 500...599: return "Apple's servers may be having issues. Check https://developer.apple.com/system-status/"
        default: return "Check the response details above."
        }
    }
}
