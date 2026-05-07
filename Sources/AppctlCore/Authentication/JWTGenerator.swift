import Crypto
import Foundation

// `@unchecked Sendable`: cached token + expiry are mutable, guarded by `lock`.
// An actor would be more idiomatic but would force every call site of `token()`
// to become async, which would cascade through `APIClient.buildRequest`. The
// lock is sufficient and keeps the call sites simple.
public final class JWTGenerator: @unchecked Sendable {
    private let keyID: String
    private let issuerID: String
    private let privateKey: P256.Signing.PrivateKey
    private var cachedToken: String?
    private var tokenExpiry: Date?
    private let lock = NSLock()
    private let tokenLifetime: TimeInterval = 15 * 60
    private let refreshMargin: TimeInterval = 60

    public init(keyID: String, issuerID: String, privateKeyPEM: String) throws {
        self.keyID = keyID
        self.issuerID = issuerID
        let cleaned = privateKeyPEM.replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let keyData = Data(base64Encoded: cleaned) else {
            throw AppctlError.invalidKeyFile(path: "(in-memory)", reason: "Invalid base64 in private key.")
        }
        do { self.privateKey = try P256.Signing.PrivateKey(derRepresentation: keyData) } catch {
            throw AppctlError.jwtGenerationFailed(reason: "Could not parse private key: \(error.localizedDescription)")
        }
    }

    public convenience init(keyID: String, issuerID: String, privateKeyPath: String) throws {
        let path = (privateKeyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw AppctlError.fileNotFound(path: path) }
        guard FileManager.default.isReadableFile(atPath: path) else { throw AppctlError.fileNotReadable(path: path) }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        guard pem.contains("BEGIN PRIVATE KEY") else {
            throw AppctlError.invalidKeyFile(
                path: path, reason: "File should start with '-----BEGIN PRIVATE KEY-----'.")
        }
        try self.init(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem)
    }

    public func token() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedToken, let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-refreshMargin) {
            return cached
        }
        let t = try generateToken()
        cachedToken = t
        tokenExpiry = Date().addingTimeInterval(tokenLifetime)
        return t
    }

    private func generateToken() throws -> String {
        let now = Date()
        let exp = now.addingTimeInterval(tokenLifetime)
        let header = try JSONSerialization.data(
            withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"] as [String: String], options: .sortedKeys)
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "iss": issuerID, "iat": Int(now.timeIntervalSince1970), "exp": Int(exp.timeIntervalSince1970),
                "aud": "appstoreconnect-v1",
            ] as [String: Any], options: .sortedKeys)
        let input = "\(b64url(header)).\(b64url(payload))"
        guard let inputData = input.data(using: .utf8) else {
            throw AppctlError.jwtGenerationFailed(reason: "UTF-8 encoding failed.")
        }
        let sig = try privateKey.signature(for: inputData)
        return "\(input).\(b64url(sig.rawRepresentation))"
    }

    private func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct AuthStore {
    public static func validateKeyFile(at path: String) -> Result<Void, AppctlError> {
        let resolved = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolved) else { return .failure(.fileNotFound(path: resolved)) }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            return .failure(.fileNotReadable(path: resolved))
        }
        do {
            let content = try String(contentsOfFile: resolved, encoding: .utf8)
            guard content.contains("BEGIN PRIVATE KEY") else {
                return .failure(.invalidKeyFile(path: resolved, reason: "Not a valid .p8 key file."))
            }
            _ = try JWTGenerator(keyID: "test", issuerID: "test", privateKeyPEM: content)
            return .success(())
        } catch let e as AppctlError { return .failure(e) } catch {
            return .failure(.invalidKeyFile(path: resolved, reason: error.localizedDescription))
        }
    }

    public static func createGenerator(from config: AppctlConfig) throws -> JWTGenerator {
        guard let keyID = config.keyID else { throw AppctlError.missingAPIKey(detail: "Key ID is not configured.") }
        guard let issuerID = config.issuerID else {
            throw AppctlError.missingAPIKey(detail: "Issuer ID is not configured.")
        }
        guard let keyPath = config.privateKeyPath else {
            throw AppctlError.missingAPIKey(detail: "Private key path is not configured.")
        }
        return try JWTGenerator(keyID: keyID, issuerID: issuerID, privateKeyPath: keyPath)
    }
}
