import Foundation
import Testing

@testable import Trio

@Suite("AI privacy and persistence", .serialized) struct AIAssistantTests {
    @Test("Medical sharing defaults off") func conservativeDefaults() throws {
        let settings = AIConfiguration()
        #expect(!settings.enabled)
        #expect(!settings.hasConsent)
        #expect(settings.historyHours == .six)
        #expect(settings.categories.isEmpty)
        #expect(!settings.remoteContinuity)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!json.contains("apiKey"))
    }

    @Test("Secret formats are removed before request serialization") func secrets() throws {
        let secrets = ["sk-proj-testSecret123456789", "nightscoutSuperSecret", "headerSecret123",
                       "urlPassword123", "querySecret123", "plainPassword123", "basicSecret123"]
        let text = """
        key sk-proj-testSecret123456789
        api-secret: nightscoutSuperSecret
        Authorization: Bearer headerSecret123
        https://user:urlPassword123@example.org/api?token=querySecret123&count=3
        password = plainPassword123
        Authorization: Basic basicSecret123
        """
        let redactor = DefaultAIContextRedactor()
        let request = OpenAIRequest(model: "test-model", instructions: "explain", input: [
            .init(role: "user", content: redactor.redact(text))
        ], previousResponseID: nil, store: false)
        let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        for secret in secrets { #expect(!body.contains(secret)) }
        #expect(body.contains("[REDACTED]"))
    }

    @Test("Composite authentication headers and escaped quotes never leak credential fragments") func compositeHeaders() throws {
        let redactor = DefaultAIContextRedactor()
        let fixtures = [
            "Cookie: session=fixture-one; auth_session=fixture-two",
            "Authorization: Digest username=\"fixture-user\", nonce=\"fixture-nonce\", response=\"fixture-response\"",
            #"{"password":"first\"second"}"#,
            #"{\"password\":\"fixture-secret\"}"#
        ]
        for fixture in fixtures {
            let data = try JSONEncoder().encode(["log": fixture])
            let sanitized = try redactor.sanitizeJSON(data)
            let request = OpenAIRequest(model: "test", instructions: "explain", input: [
                .init(role: "user", content: String(decoding: sanitized, as: UTF8.self))
            ], previousResponseID: nil, store: false)
            let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            for secret in ["fixture-one", "fixture-two", "fixture-user", "fixture-nonce", "fixture-response", "fixture-secret", "first", "second"] {
                #expect(!body.contains(secret))
            }
        }
    }

    @Test("Nested JSON and exact known credentials are redacted") func structuredSecrets() throws {
        let redactor = DefaultAIContextRedactor(knownSecrets: { ["unlabelled-secret-567"] })
        let data = Data(#"{"nested":{"access_token":"token-value-123","safe":"glucose 123"},"log":"unlabelled-secret-567"}"#.utf8)
        let sanitized = try redactor.sanitizeJSON(data)
        let text = String(decoding: sanitized, as: UTF8.self)
        #expect(!text.contains("token-value-123"))
        #expect(!text.contains("unlabelled-secret-567"))
        #expect(text.contains("glucose 123"))
        #expect(try JSONSerialization.jsonObject(with: sanitized) is [String: Any])
    }

    @Test("Conversation and response ID survive reopening; rename and delete persist") func persistence() throws {
        let path = "ai-tests/\(UUID().uuidString).json"
        defer { try? Disk.remove(path, from: .temporary) }
        let store = DiskAIConversationStore(directory: .temporary, path: path)
        var archive = try store.load()
        var conversation = AIConversation(title: "SMB explanation")
        conversation.messages = [.init(role: .user, content: "Why at 02:00?")]
        conversation.lastResponseID = "resp_fixture"
        archive.conversations = [conversation]
        try store.save(archive)
        let reopened = DiskAIConversationStore(directory: .temporary, path: path)
        var restored = try reopened.load()
        #expect(restored.conversations.first?.lastResponseID == "resp_fixture")
        #expect(restored.conversations.first?.messages.first?.content == "Why at 02:00?")
        #expect(restored.conversations.first?.createdAt.timeIntervalSince1970.rounded() ==
            conversation.createdAt.timeIntervalSince1970.rounded())
        restored.conversations[0].title = "Renamed"
        try reopened.save(restored)
        #expect(try store.load().conversations.first?.title == "Renamed")
        restored.conversations.removeAll()
        try reopened.save(restored)
        #expect(try store.load().conversations.isEmpty)
    }

    @Test("Corruption is surfaced instead of overwriting conversations") func corruptArchive() throws {
        let path = "ai-tests/\(UUID().uuidString).json"
        defer { try? Disk.remove(path, from: .temporary) }
        try Disk.save(Data("not JSON".utf8), to: .temporary, as: path)
        #expect(throws: (any Error).self) {
            try DiskAIConversationStore(directory: .temporary, path: path).load()
        }
    }
}
