import Crypto
import Foundation
import Testing

@testable import AppctlCore

/// Probes once whether the login keychain is writable — it is not in headless
/// sessions (CI without an unlocked keychain), where the suite skips instead of
/// failing.
private enum KeychainProbe {
    static let isAvailable: Bool = {
        let store = KeychainCredentialStore(service: "com.appctl.credentials.probe-\(UUID().uuidString)")
        do {
            try store.store("probe", account: .keyID)
            try store.delete(.keyID)
            return true
        } catch {
            return false
        }
    }()
}

@Suite(
    "Keychain credential store",
    .enabled(if: KeychainProbe.isAvailable, "Login keychain is unavailable in this environment.")
)
struct KeychainRoundTripTests {
    private static func uniqueStore() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.appctl.credentials.test-\(UUID().uuidString)")
    }

    private static func cleanUp(_ store: KeychainCredentialStore) {
        for account in KeychainCredentialStore.Account.allCases {
            try? store.delete(account)
        }
    }

    @Test func roundTripStoreReadOverwriteDelete() throws {
        let store = Self.uniqueStore()
        defer { Self.cleanUp(store) }
        let pem = P256.Signing.PrivateKey().pemRepresentation

        try store.store("KEY123", account: .keyID)
        try store.store("issuer-abc", account: .issuerID)
        try store.store(pem, account: .privateKey)
        #expect(try store.read(.keyID) == "KEY123")
        #expect(try store.read(.issuerID) == "issuer-abc")
        #expect(try store.read(.privateKey) == pem)

        // Re-running setup must overwrite (SecItemAdd → errSecDuplicateItem → SecItemUpdate).
        try store.store("KEY456", account: .keyID)
        #expect(try store.read(.keyID) == "KEY456")

        #expect(try store.delete(.keyID) == true)
        #expect(try store.read(.keyID) == nil)
        #expect(try store.delete(.keyID) == false)
    }

    @Test func configLoaderResolvesKeychainBetweenEnvAndFile() throws {
        let env = ProcessInfo.processInfo.environment
        // Env credentials outrank the keychain; assertions below would be testing
        // the wrong layer if the host shell exports them.
        guard env["APPCTL_KEY_ID"] == nil, env["APPCTL_ISSUER_ID"] == nil,
            env["APPCTL_PRIVATE_KEY_PATH"] == nil
        else { return }

        let store = Self.uniqueStore()
        defer { Self.cleanUp(store) }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        try store.store("KC-KEY", account: .keyID)
        try store.store("KC-ISSUER", account: .issuerID)
        try store.store(pem, account: .privateKey)

        let config = try ConfigLoader.load(keychain: store)
        #expect(config.keyID == "KC-KEY")
        #expect(config.issuerID == "KC-ISSUER")
        #expect(config.privateKeyPEM == pem)
        #expect(config.privateKeyPath == nil, "Keychain PEM must win over any config-file key path")

        let flagged = try ConfigLoader.load(keyIDOverride: "FLAG-KEY", keychain: store)
        #expect(flagged.keyID == "FLAG-KEY", "Flags must outrank the keychain")
    }
}
