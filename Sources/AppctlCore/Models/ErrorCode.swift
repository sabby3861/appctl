import Foundation

/// Stable, machine-readable error codes. These are a public contract: agents and
/// scripts branch on them, so a case may be added but never renamed or removed.
/// Every code has an anchor in docs/errors.md and belongs to one exit class.
public enum ErrorCode: String, Sendable, CaseIterable {
    // Exit class 4 — authentication and authorization.
    case authMissingKey = "AUTH_MISSING_KEY"
    case authInvalidKeyFile = "AUTH_INVALID_KEY_FILE"
    case authJWTFailed = "AUTH_JWT_FAILED"
    case authTokenExpired = "AUTH_TOKEN_EXPIRED"
    case authUnauthorized = "AUTH_UNAUTHORIZED"
    case authAgreementPending = "AUTH_AGREEMENT_PENDING"
    case authKeychain = "AUTH_KEYCHAIN"
    case authAltoolKeyNotFound = "AUTH_ALTOOL_KEY_NOT_FOUND"

    // Exit class 1 — command usage.
    case usageInvalidArgument = "USAGE_INVALID_ARGUMENT"
    case usageMissingField = "USAGE_MISSING_FIELD"
    case usageConfigNotFound = "USAGE_CONFIG_NOT_FOUND"
    case usageConfirmationRequired = "USAGE_CONFIRMATION_REQUIRED"
    case usageUnsupported = "USAGE_UNSUPPORTED"
    case usageCancelled = "USAGE_CANCELLED"

    // Exit class 2 — local validation of user-supplied content.
    case validationCharLimit = "VALIDATION_CHAR_LIMIT"
    case validationScreenshot = "VALIDATION_SCREENSHOT"
    case validationConfigParse = "VALIDATION_CONFIG_PARSE"
    case validationFileNotFound = "VALIDATION_FILE_NOT_FOUND"
    case validationFileNotReadable = "VALIDATION_FILE_NOT_READABLE"
    case validationFileWrite = "VALIDATION_FILE_WRITE"
    case validationSigningCertExpired = "VALIDATION_SIGNING_CERT_EXPIRED"
    case validationSigningCertNotFound = "VALIDATION_SIGNING_CERT_NOT_FOUND"
    case validationSigningProfileMismatch = "VALIDATION_SIGNING_PROFILE_MISMATCH"
    case validationSigningIdentityNotFound = "VALIDATION_SIGNING_IDENTITY_NOT_FOUND"

    // Exit class 3 — the App Store Connect API (or an external tool) said no.
    case apiError = "API_ERROR"
    case apiRequestFailed = "API_REQUEST_FAILED"
    case apiRateLimited = "API_RATE_LIMITED"
    case apiResourceLocked = "API_RESOURCE_LOCKED"
    case apiNotFound = "API_NOT_FOUND"
    case apiConflict = "API_CONFLICT"
    case apiPartialFailure = "API_PARTIAL_FAILURE"
    case apiInvalidResponse = "API_INVALID_RESPONSE"
    case apiBuildProcessingFailed = "API_BUILD_PROCESSING_FAILED"
    case apiSchemaUnavailable = "API_SCHEMA_UNAVAILABLE"
    case subprocessFailed = "SUBPROCESS_FAILED"

    // Exit class 5 — the network, not the API.
    case networkTimeout = "NETWORK_TIMEOUT"
    case networkConnectionFailed = "NETWORK_CONNECTION_FAILED"
    case uploadPartFailed = "UPLOAD_PART_FAILED"

    /// Exit-code classes: 1 usage, 2 validation, 3 API, 4 auth, 5 network.
    public var exitClass: Int32 {
        switch self {
        case .usageInvalidArgument, .usageMissingField, .usageConfigNotFound,
            .usageConfirmationRequired, .usageUnsupported, .usageCancelled:
            return 1
        case .validationCharLimit, .validationScreenshot, .validationConfigParse,
            .validationFileNotFound, .validationFileNotReadable, .validationFileWrite,
            .validationSigningCertExpired, .validationSigningCertNotFound,
            .validationSigningProfileMismatch, .validationSigningIdentityNotFound:
            return 2
        case .apiError, .apiRequestFailed, .apiRateLimited, .apiResourceLocked,
            .apiNotFound, .apiConflict, .apiPartialFailure, .apiInvalidResponse,
            .apiBuildProcessingFailed, .apiSchemaUnavailable, .subprocessFailed:
            return 3
        case .authMissingKey, .authInvalidKeyFile, .authJWTFailed, .authTokenExpired,
            .authUnauthorized, .authAgreementPending, .authKeychain, .authAltoolKeyNotFound:
            return 4
        case .networkTimeout, .networkConnectionFailed, .uploadPartFailed:
            return 5
        }
    }

    /// GitHub renders `## AUTH_MISSING_KEY` as anchor `#auth_missing_key`.
    public var docsURL: String {
        "https://github.com/sabby3861/appctl/blob/main/docs/errors.md#\(rawValue.lowercased())"
    }
}

extension AppctlError {
    /// The stable code for this failure. HTTP-level knowledge stays in `AppctlError`;
    /// Apple's JSON:API error codes refine the mapping (a 403 caused by an unsigned
    /// agreement is an account problem, not a request problem).
    public var errorCode: ErrorCode {
        switch self {
        case .missingAPIKey: return .authMissingKey
        case .invalidKeyFile: return .authInvalidKeyFile
        case .jwtGenerationFailed: return .authJWTFailed
        case .tokenExpired: return .authTokenExpired
        case .unauthorized: return .authUnauthorized
        case .agreementPending: return .authAgreementPending
        case .keychainError: return .authKeychain
        case .altoolKeyNotFound: return .authAltoolKeyNotFound

        case .invalidInput: return .usageInvalidArgument
        case .missingRequiredField: return .usageMissingField
        case .configNotFound: return .usageConfigNotFound
        case .confirmationRequired: return .usageConfirmationRequired
        case .unsupportedOperation: return .usageUnsupported
        case .operationCancelled: return .usageCancelled

        case .charLimitExceeded: return .validationCharLimit
        case .screenshotValidationFailed: return .validationScreenshot
        case .configParseError: return .validationConfigParse
        case .fileNotFound: return .validationFileNotFound
        case .fileNotReadable: return .validationFileNotReadable
        case .fileWriteError: return .validationFileWrite
        case .certificateExpired: return .validationSigningCertExpired
        case .certificateNotFound: return .validationSigningCertNotFound
        case .profileMismatch: return .validationSigningProfileMismatch
        case .signingIdentityNotFound: return .validationSigningIdentityNotFound

        case .apiError(_, _, let errors): return Self.refineAPIError(errors)
        case .requestFailed: return .apiRequestFailed
        case .rateLimited: return .apiRateLimited
        case .resourceNotFound: return .apiNotFound
        case .conflictError: return .apiConflict
        case .partialFailure: return .apiPartialFailure
        case .invalidResponse: return .apiInvalidResponse
        case .buildProcessingFailed: return .apiBuildProcessingFailed
        case .schemaUnavailable: return .apiSchemaUnavailable
        case .subprocessFailed: return .subprocessFailed

        case .timeout: return .networkTimeout
        case .connectionFailed: return .networkConnectionFailed
        case .uploadPartFailed: return .uploadPartFailed
        }
    }

    private static func refineAPIError(_ errors: [APIErrorDetail]) -> ErrorCode {
        for e in errors {
            if e.code.hasPrefix("STATE_ERROR") { return .apiResourceLocked }
            let text = "\(e.title) \(e.detail ?? "")".lowercased()
            if e.code.hasPrefix("FORBIDDEN"), text.contains("agreement") {
                return .authAgreementPending
            }
        }
        return .apiError
    }
}
