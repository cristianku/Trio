import Foundation
import Testing

@testable import Trio

@Suite("AI Keychain credential boundary", .serialized) struct AICredentialTests {
    @Test("Key replacement and deletion use only an isolated Keychain entry") func keychain() throws {
        let keychain = BaseKeychain(serviceName: "Trio.AI.UnitTests.\(UUID().uuidString)", synchronizable: false,
                                    accessibilityLevel: .whenUnlockedThisDeviceOnly)
        defer { keychain.removeObject(forKey: KeychainAICredentialProvider.key) }
        let provider = KeychainAICredentialProvider(keychain: keychain)
        #expect(throws: (any Error).self) { try provider.apiKey() }
        try provider.replaceKey("sk-proj-unitFixture123")
        #expect(try provider.apiKey() == "sk-proj-unitFixture123")
        #expect(try keychain.accessibilityOfKey(KeychainAICredentialProvider.key).get() == .whenUnlockedThisDeviceOnly)
        #expect(UserDefaults.standard.object(forKey: KeychainAICredentialProvider.key) == nil)
        let persisted = String(decoding: try JSONEncoder().encode(AIArchive()), as: UTF8.self)
        #expect(!persisted.contains("sk-proj-unitFixture123"))
        try provider.replaceKey("sk-proj-replacementFixture456")
        #expect(try provider.apiKey() == "sk-proj-replacementFixture456")
        try provider.deleteKey()
        #expect(throws: (any Error).self) { try provider.apiKey() }
    }
}
