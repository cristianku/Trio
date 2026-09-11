import Foundation
import Testing
import Swinject

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
        #expect(try provider.maskedAPIKey() == "sk-proj-un…e123")
        #expect(try keychain.accessibilityOfKey(KeychainAICredentialProvider.key).get() == .whenUnlockedThisDeviceOnly)
        #expect(UserDefaults.standard.object(forKey: KeychainAICredentialProvider.key) == nil)
        let persisted = String(decoding: try JSONEncoder().encode(AIArchive()), as: UTF8.self)
        #expect(!persisted.contains("sk-proj-unitFixture123"))
        try provider.replaceKey("sk-proj-replacementFixture456")
        #expect(try provider.apiKey() == "sk-proj-replacementFixture456")
        try provider.deleteKey()
        #expect(throws: (any Error).self) { try provider.apiKey() }
    }

    @Test("Short credentials never appear in full in the preview") func shortPreview() throws {
        let keychain = BaseKeychain(serviceName: "Trio.AI.UnitTests.\(UUID().uuidString)", synchronizable: false,
                                    accessibilityLevel: .whenUnlockedThisDeviceOnly)
        defer { keychain.removeObject(forKey: KeychainAICredentialProvider.key) }
        let provider = KeychainAICredentialProvider(keychain: keychain)
        for value in ["x", "sk-short", "123456789012345678"] {
            try provider.replaceKey(value)
            #expect(try provider.maskedAPIKey() == "••••••••")
        }
    }

    @Test("The key preview survives reload and failed replacement preserves the saved key") @MainActor
    func savedPreview() throws {
        let keychain = BaseKeychain(serviceName: "Trio.AI.UnitTests.\(UUID().uuidString)", synchronizable: false,
                                    accessibilityLevel: .whenUnlockedThisDeviceOnly)
        defer { keychain.removeObject(forKey: KeychainAICredentialProvider.key) }
        let credentials = KeychainAICredentialProvider(keychain: keychain)
        let store = MemoryAIStore()
        let service = DefaultAIService(store: store, builder: AIBuilderFixture(), redactor: DefaultAIContextRedactor(),
                                       client: AIClientFixture())
        let container = Container()
        container.register(AIService.self) { _ in service }
        container.register(AICredentialProvider.self) { _ in credentials }
        let state = AIAssistant.StateModel(provider: AIAssistant.Provider(resolver: container))
        #expect(!state.hasKey)
        #expect(state.keyPreview == nil)
        #expect(state.replaceKey("sk-proj-unitFixture123"))
        #expect(state.hasKey)
        #expect(state.keyPreview == "sk-proj-un…e123")
        #expect(!state.replaceKey("invalid key"))
        #expect(try credentials.apiKey() == "sk-proj-unitFixture123")
        #expect(state.keyPreview == "sk-proj-un…e123")
        state.reload()
        #expect(state.keyPreview == "sk-proj-un…e123")
        #expect(state.replaceKey("sk-proj-replacementFixture456"))
        #expect(state.keyPreview == "sk-proj-re…e456")
        #expect(state.errorMessage == nil)
        #expect(!String(decoding: try JSONEncoder().encode(store.archive), as: UTF8.self).contains("sk-proj-"))
    }
}
