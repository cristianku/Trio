import Foundation
import Testing

@testable import Trio

@Suite("AI message formatting") struct AIMessageFormattingTests {
    @Test("Assistant emphasis renders without losing paragraphs or glucose units")
    func emphasis() throws {
        let message = AIMessage(role: .assistant, content: "Glukoza **92 mg/dl**.\n\n- Trend *płaski*.\n- `IOB` to szacunek.")
        let result = AIMessageFormatting.content(message)
        #expect(String(result.characters) == "Glukoza 92 mg/dl.\n\n- Trend płaski.\n- IOB to szacunek.")
        let bold = try #require(result.range(of: "92 mg/dl"))
        #expect(result[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        let italic = try #require(result.range(of: "płaski"))
        #expect(result[italic].inlinePresentationIntent?.contains(.emphasized) == true)
    }

    @Test("Generated links and images have no interactive or image attributes")
    func inertContent() {
        let message = AIMessage(role: .assistant, content: "[**Settings**](https://example.org) ![image](https://example.org/image.png)")
        let result = AIMessageFormatting.content(message)
        #expect(!String(result.characters).contains("https://"))
        #expect(String(result.characters).contains("Settings"))
        for run in result.runs {
            #expect(run.link == nil)
            #expect(run.imageURL == nil)
        }
    }

    @Test("User text and unmatched emphasis remain literal")
    func literalContent() {
        let user = AIMessage(role: .user, content: "**my text**\n2 * 3 < 10")
        #expect(String(AIMessageFormatting.content(user).characters) == user.content)
        #expect(AIMessageFormatting.content(user).runs.allSatisfy { $0.inlinePresentationIntent == nil })
        let unfinished = AIMessage(role: .assistant, content: "Glucose **92 mg/dl")
        #expect(String(AIMessageFormatting.content(unfinished).characters) == unfinished.content)
    }
}

@Suite("AI privacy and persistence", .serialized) struct AIAssistantTests {
    @Test("Older archives remain readable and manual selection persists")
    func contextModeMigration() throws {
        let old = #"{"enabled":true,"consentVersion":1,"model":"gpt-4.1-mini","historyHours":6,"categories":["glucose"],"warningsOnly":true,"remoteContinuity":false}"#
        var config = try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8))
        #expect(config.automaticallySelectContext)
        #expect(config.categories == [.glucose])
        config.automaticallySelectContext = false
        config.historyHours = .sevenDays
        let restored = try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config))
        #expect(!restored.automaticallySelectContext)
        #expect(restored.historyHours == .sevenDays)
    }

    @Test("Graph question includes the viewport interval, including the future forecast portion")
    func graphQuestion() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1800000000), duration: 6 * 3600)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let question = AIChartQuestion.make(interval: interval)
        #expect(question.contains(formatter.string(from: interval.start)))
        #expect(question.contains(formatter.string(from: interval.end)))
    }

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
