import Foundation
import Testing
import Swinject

@testable import Trio

@Suite("AI service consent and continuity", .serialized) @MainActor struct AIServiceTests {
    @Test("Automatic preview is local and a no-data question does not read device records")
    func noDataSelection() async throws {
        let store = MemoryAIStore()
        store.archive.configuration.enabled = true
        store.archive.configuration.consentVersion = AIPrompt.consentVersion
        store.archive.configuration.categories = [.settings, .glucose]
        let client = AIPlanningClientFixture(plan: #"{"startHoursAgo":1,"endHoursAgo":0,"categories":[]}"#)
        let service = DefaultAIService(store: store, builder: TrioAIContextBuilder(source: FailingAISource(), logs: EmptyAILogs()),
                                       redactor: DefaultAIContextRedactor(), client: client)
        let preview = try await service.previewContext()
        #expect(preview.contains("168"))
        #expect(client.requests.isEmpty)
        let chat = try service.newConversation()
        _ = try await service.send("What is a glucose sensor?", conversationID: chat.id)
        #expect(client.requests.count == 2)
        #expect(!client.requests[1].input.contains { $0.content.contains("glucoseMgDL") })
    }

    @Test("Cancelling planning prevents data collection and the answer request")
    func cancelledPlanning() async throws {
        let store = MemoryAIStore()
        store.archive.configuration.enabled = true
        store.archive.configuration.consentVersion = AIPrompt.consentVersion
        let client = AIPlanningClientFixture(plan: "{}")
        client.waitForCancellation = true
        let builder = AIBuilderFixture()
        let service = DefaultAIService(store: store, builder: builder, redactor: DefaultAIContextRedactor(), client: client)
        let chat = try service.newConversation()
        let task = Task { try await service.send("Explain", conversationID: chat.id) }
        while client.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(client.requests.count == 1)
        #expect(builder.calls == 0)
        #expect(store.archive.conversations[0].messages.isEmpty)
    }

    @Test("Automatic selection sends no medical snapshot to planning and only chosen data to answering")
    func automaticSelection() async throws {
        let store = MemoryAIStore()
        let source = ContextSourceFixture(now: Date())
        let builder = TrioAIContextBuilder(source: source, logs: EmptyAILogs())
        let client = AIPlanningClientFixture(plan: #"{"startHoursAgo":1,"endHoursAgo":0,"categories":["settings"]}"#)
        let service = DefaultAIService(store: store, builder: builder, redactor: DefaultAIContextRedactor(), client: client)
        var config = AIConfiguration()
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        config.categories = [.settings, .glucose]
        config.remoteContinuity = true
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("Check my settings", conversationID: chat.id)
        #expect(client.requests.count == 2)
        #expect(client.requests[0].text != nil)
        #expect(!client.requests[0].input.contains { $0.content.contains("glucoseMgDL") })
        #expect(!client.requests[1].input.contains { $0.content.contains("glucoseMgDL") })
        #expect(client.requests[1].input.contains { $0.content.contains("configuration") })
        #expect(client.requests.allSatisfy { !$0.store && $0.previousResponseID == nil })
        #expect(store.archive.conversations[0].messages.count == 2)
    }

    @Test("Invalid automatic plans cannot broaden sharing or trigger an answer request",
          arguments: [#"{"startHoursAgo":169,"endHoursAgo":0,"categories":["glucose"]}"#,
                      #"{"startHoursAgo":6,"endHoursAgo":7,"categories":["glucose"]}"#,
                      #"{"startHoursAgo":6,"endHoursAgo":0,"categories":["logs"]}"#,
                      "Not a JSON plan"])
    func invalidSelection(plan: String) async throws {
        let store = MemoryAIStore()
        store.archive.configuration.enabled = true
        store.archive.configuration.consentVersion = AIPrompt.consentVersion
        store.archive.configuration.categories = [.glucose]
        let client = AIPlanningClientFixture(plan: plan)
        let builder = AIBuilderFixture()
        let service = DefaultAIService(store: store, builder: builder, redactor: DefaultAIContextRedactor(), client: client)
        let chat = try service.newConversation()
        await #expect(throws: (any Error).self) { try await service.send("Check last night", conversationID: chat.id) }
        #expect(client.requests.count == 1)
        #expect(builder.calls == 0)
        #expect(store.archive.conversations[0].messages.isEmpty)
    }

    @Test("Each request uses the current app language, including remote conversation continuations",
          arguments: [false, true])
    func responseLanguage(remoteContinuity: Bool) async throws {
        let store = MemoryAIStore()
        let client = AIClientFixture()
        var appLanguage = "it"
        let service = DefaultAIService(store: store, builder: AIBuilderFixture(), redactor: DefaultAIContextRedactor(),
                                       client: client, languageIdentifier: { appLanguage })
        var config = AIConfiguration()
        config.automaticallySelectContext = false
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        config.remoteContinuity = remoteContinuity
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("Please check Trio settings", conversationID: chat.id)
        #expect(client.requests[0].instructions.contains("Response language: Italian (it)."))
        appLanguage = "pl"
        _ = try await service.send("Controlla le impostazioni", conversationID: chat.id)
        #expect(client.requests[1].instructions.contains("Response language: Polish (pl)."))
        #expect(!client.requests[1].instructions.contains("Response language: Italian (it)."))
        #expect(client.requests[1].previousResponseID == (remoteContinuity ? "resp_test" : nil))
        #expect(client.requests[1].instructions.contains("Do not give personalized dosing instructions."))
    }

    @Test("Disabled and unconsented requests never reach network") func consent() async throws {
        let store = MemoryAIStore()
        let client = AIClientFixture()
        let service = DefaultAIService(store: store, builder: AIBuilderFixture(), redactor: DefaultAIContextRedactor(), client: client)
        let chat = try service.newConversation()
        await #expect(throws: (any Error).self) { try await service.send("Why?", conversationID: chat.id) }
        var config = try service.load().configuration
        config.enabled = true
        try service.updateConfiguration(config)
        await #expect(throws: (any Error).self) { try await service.send("Why?", conversationID: chat.id) }
        #expect(client.requests.isEmpty)
        #expect(try service.load().conversations.first?.messages.isEmpty == true)
    }

    @Test("Every send builds fresh context and stores both messages and response ID") func freshContext() async throws {
        let store = MemoryAIStore()
        let builder = AIBuilderFixture()
        let client = AIClientFixture()
        let service = DefaultAIService(store: store, builder: builder, redactor: DefaultAIContextRedactor(), client: client)
        var config = AIConfiguration()
        config.automaticallySelectContext = false
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("first", conversationID: chat.id)
        _ = try await service.send("second", conversationID: chat.id)
        #expect(builder.calls == 2)
        #expect(client.requests.count == 2)
        #expect(client.requests[1].input.contains { $0.content.contains("snapshot 2") })
        #expect(client.requests[1].input.contains { $0.content == "first" })
        #expect(client.requests[1].previousResponseID == nil)
        #expect(!client.requests[1].store)
        let restored = try service.load()
        #expect(restored.conversations[0].messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(restored.conversations[0].lastResponseID == "resp_test")
        #expect((restored.lastRequestBytes ?? 0) > 0)
    }

    @Test("Failed context building and cancellation preserve the correct conversation draft") func retainedDraft() async throws {
        let store = MemoryAIStore()
        store.archive.configuration.automaticallySelectContext = false
        store.archive.configuration.enabled = true
        store.archive.configuration.consentVersion = AIPrompt.consentVersion
        let service = DefaultAIService(store: store, builder: FailingAIBuilder(), redactor: DefaultAIContextRedactor(), client: AIClientFixture())
        let container = Container()
        container.register(AIService.self) { _ in service }
        container.register(AICredentialProvider.self) { _ in FixtureAICredentials() }
        let state = AIAssistant.StateModel(provider: AIAssistant.Provider(resolver: container))
        let chat = try #require(state.newConversation())
        state.setDraft("Keep my question", for: chat)
        state.send(conversationID: chat)
        while state.isLoading { await Task.yield() }
        #expect(state.draft(for: chat) == "Keep my question")
        #expect(state.conversation(chat)?.messages.isEmpty == true)
        let otherChat = try #require(state.newConversation())
        #expect(state.draft(for: otherChat).isEmpty)
        state.send(conversationID: chat)
        state.cancel()
        while state.isLoading { await Task.yield() }
        #expect(state.draft(for: chat) == "Keep my question")
    }

    @Test("Remote continuity is opt in and resets after privacy changes") func continuity() async throws {
        let store = MemoryAIStore()
        let client = AIClientFixture()
        let service = DefaultAIService(store: store, builder: AIBuilderFixture(), redactor: DefaultAIContextRedactor(), client: client)
        var config = AIConfiguration()
        config.automaticallySelectContext = false
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        config.remoteContinuity = true
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("first", conversationID: chat.id)
        client.onRequest = { _ in
            #expect(store.archive.conversations[0].lastResponseID == nil)
            #expect(store.archive.conversations[0].messages.last?.content == "second")
        }
        _ = try await service.send("second", conversationID: chat.id)
        client.onRequest = nil
        #expect(client.requests[1].previousResponseID == "resp_test")
        config.categories = [.glucose]
        try service.updateConfiguration(config)
        #expect(try service.load().conversations[0].lastResponseID == nil)
        _ = try await service.send("third", conversationID: chat.id)
        #expect(client.requests[2].previousResponseID == nil)
    }

    @Test("Preview and send sanitize the same fresh medical context without preview network traffic") func sanitizedPreview() async throws {
        let store = MemoryAIStore()
        let client = AIClientFixture()
        let service = DefaultAIService(store: store, builder: SecretAIBuilder(), redactor: DefaultAIContextRedactor(), client: client)
        store.archive.configuration.automaticallySelectContext = false
        let preview = try await service.previewContext()
        #expect(!preview.contains("contextSecret123"))
        #expect(preview.contains("REDACTED"))
        #expect(client.requests.isEmpty)
        var config = AIConfiguration()
        config.automaticallySelectContext = false
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        config.categories = [.logs]
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("Explain logs", conversationID: chat.id)
        let body = String(decoding: try JSONEncoder().encode(client.requests[0]), as: UTF8.self)
        #expect(!body.contains("contextSecret123"))
        #expect(body.contains("REDACTED"))
        #expect(try JSONSerialization.jsonObject(with: Data(preview.utf8)) is [String: Any])
    }

    @Test("User-entered credentials cannot be saved in conversation or sent in body") func noPersistedSecrets() async throws {
        let store = MemoryAIStore()
        let client = AIClientFixture()
        let secret = "sk-proj-privateFixture123"
        let service = DefaultAIService(store: store, builder: AIBuilderFixture(), redactor: DefaultAIContextRedactor(knownSecrets: { [secret] }), client: client)
        var config = AIConfiguration()
        config.automaticallySelectContext = false
        config.enabled = true
        config.consentVersion = AIPrompt.consentVersion
        try service.updateConfiguration(config)
        let chat = try service.newConversation()
        _ = try await service.send("Explain \(secret)", conversationID: chat.id)
        let archive = String(decoding: try JSONEncoder().encode(store.archive), as: UTF8.self)
        let request = String(decoding: try JSONEncoder().encode(client.requests[0]), as: UTF8.self)
        #expect(!archive.contains(secret))
        #expect(!request.contains(secret))
    }
}

final class AIPlanningClientFixture: OpenAIClient {
    let plan: String
    var requests: [OpenAIRequest] = []
    var waitForCancellation = false
    init(plan: String) { self.plan = plan }
    func respond(to request: OpenAIRequest) async throws -> OpenAIResponse {
        requests.append(request)
        if waitForCancellation { try await Task.sleep(nanoseconds: 10_000_000_000) }
        let text = request.text == nil ? "Explanation" : plan
        let payload: [String: Any] = ["id": "resp_test", "status": "completed", "output": [
            ["type": "message", "content": [["type": "output_text", "text": text]]]
        ]]
        return try JSONDecoder().decode(OpenAIResponse.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

final class MemoryAIStore: AIConversationStore {
    var archive = AIArchive()
    func load() throws -> AIArchive { archive }
    func save(_ archive: AIArchive) throws { self.archive = archive }
}

final class AIBuilderFixture: AIContextBuilder {
    var calls = 0
    func build(configuration: AIConfiguration) async throws -> TrioAIContext {
        calls += 1
        var context = TrioAIContext(generatedAt: Date(), intervalStart: Date(), timeZone: "UTC", appVersion: nil, includedCategories: [])
        context.notes = ["snapshot \(calls)"]
        return context
    }
}

final class AIClientFixture: OpenAIClient {
    var requests: [OpenAIRequest] = []
    var onRequest: ((OpenAIRequest) -> Void)?
    func respond(to request: OpenAIRequest) async throws -> OpenAIResponse {
        requests.append(request)
        onRequest?(request)
        return try JSONDecoder().decode(OpenAIResponse.self, from: Data(#"{"id":"resp_test","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Explanation"}]}]}"#.utf8))
    }
}

struct FailingAIBuilder: AIContextBuilder {
    func build(configuration: AIConfiguration) async throws -> TrioAIContext { throw AIError.invalidResponse }
}

struct SecretAIBuilder: AIContextBuilder {
    func build(configuration: AIConfiguration) async throws -> TrioAIContext {
        var context = TrioAIContext(generatedAt: Date(), intervalStart: Date(), timeZone: "UTC", appVersion: nil, includedCategories: ["logs"])
        context.logs = [.init(date: Date(), category: "Nightscout", message: "Authorization: Bearer contextSecret123")]
        return context
    }
}
