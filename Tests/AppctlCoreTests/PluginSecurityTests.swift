import Crypto
import Foundation
import Testing

@testable import AppctlCore

@Suite("Plugin child environment") struct PluginChildEnvironmentTests {
    private static let pem = P256.Signing.PrivateKey().pemRepresentation

    @Test func stripsCredentialVariables() {
        let base = [
            "PATH": "/usr/bin", "HOME": "/Users/x",
            "APPCTL_KEY_ID": "KEY", "APPCTL_ISSUER_ID": "ISSUER",
            "APPCTL_PRIVATE_KEY_PATH": "/keys/AuthKey.p8",
            "APPCTL_TOKEN": "stale-inherited-token",
        ]
        let env = PluginManager.childEnvironment(base: base, token: nil)
        for key in PluginManager.credentialEnvironmentKeys {
            #expect(env[key] == nil, "\(key) must not reach the child")
        }
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/x")
    }

    @Test func neverContainsPrivateKeyMaterial() throws {
        let generator = try JWTGenerator(keyID: "T", issuerID: "I", privateKeyPEM: Self.pem)
        let base = [
            "APPCTL_PRIVATE_KEY": Self.pem,
            "SOME_UNRELATED_VAR": Self.pem,
            "PATH": "/usr/bin",
        ]
        let token = try generator.mintToken(lifetime: PluginManager.pluginTokenLifetime)
        let env = PluginManager.childEnvironment(base: base, token: token)
        for (key, value) in env {
            #expect(!value.contains("-----BEGIN PRIVATE KEY-----"), "\(key) carries PEM key material")
        }
        #expect(env["APPCTL_TOKEN"] == token)
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func passedTokenIsShortLivedOneShotMint() async throws {
        let generator = try JWTGenerator(keyID: "T", issuerID: "I", privateKeyPEM: Self.pem)
        let cached = try await generator.token()
        let minted = try generator.mintToken(lifetime: PluginManager.pluginTokenLifetime)
        #expect(minted != cached, "Plugin token must never be the cached 15-minute token")

        let cachedClaims = try Self.claims(of: cached)
        let mintedClaims = try Self.claims(of: minted)
        #expect(mintedClaims.exp - mintedClaims.iat <= 300)
        #expect(mintedClaims.exp < cachedClaims.exp, "Short-lived mint must expire before the cached token")
        #expect(try await generator.token() == cached, "Minting must not replace the cached token")
    }

    @Test func pluginTokenLifetimeIsCapped() {
        #expect(PluginManager.pluginTokenLifetime <= 300)
    }

    private static func claims(of jwt: String) throws -> (iat: Int, exp: Int) {
        let parts = jwt.split(separator: ".")
        try #require(parts.count == 3)
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let data = try #require(Data(base64Encoded: b64))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let iat = try #require(payload["iat"] as? Int)
        let exp = try #require(payload["exp"] as? Int)
        return (iat, exp)
    }
}

@Suite("Plugin manifest") struct PluginManifestTests {
    private static func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "appctl-manifest-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func absentManifestMeansNoAPIAccess() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try PluginManager.manifest(forPluginAt: "\(dir)/appctl-foo") == nil)
    }

    @Test func parsesRequiresAPIAccess() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plugin = "\(dir)/appctl-foo"
        try #"{"requiresAPIAccess": true}"#.write(
            toFile: "\(plugin).manifest.json", atomically: true, encoding: .utf8)
        #expect(try PluginManager.manifest(forPluginAt: plugin)?.requiresAPIAccess == true)
    }

    @Test func malformedManifestThrows() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plugin = "\(dir)/appctl-foo"
        try "not json".write(toFile: "\(plugin).manifest.json", atomically: true, encoding: .utf8)
        #expect(throws: AppctlError.self) {
            _ = try PluginManager.manifest(forPluginAt: plugin)
        }
    }
}
