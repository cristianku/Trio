import Foundation

@MainActor protocol AIService: AnyObject {
    func load() throws -> AIArchive
    func newConversation() throws -> AIConversation
    func renameConversation(_ id: UUID, title: String) throws
    func deleteConversation(_ id: UUID) throws
    func updateConfiguration(_ configuration: AIConfiguration) throws
    func previewContext() async throws -> String
    func send(_ message: String, conversationID: UUID) async throws -> AIConversation
}

/// Serializes local archive changes and checks consent at send time, not just in the UI.
@MainActor final class DefaultAIService: AIService {
    private let store: AIConversationStore
    private let builder: AIContextBuilder
    private let redactor: AIContextRedactor
    private let client: OpenAIClient
    private var busy = false

    init(store: AIConversationStore, builder: AIContextBuilder, redactor: AIContextRedactor, client: OpenAIClient) {
        self.store = store
        self.builder = builder
        self.redactor = redactor
        self.client = client
    }

    func load() throws -> AIArchive { try store.load() }

    func newConversation() throws -> AIConversation {
        guard !busy else { throw AIError.busy }
        var archive = try store.load()
        let conversation = AIConversation(title: "New Conversation")
        archive.conversations.insert(conversation, at: 0)
        try store.save(archive)
        return conversation
    }

    func renameConversation(_ id: UUID, title: String) throws {
        guard !busy else { throw AIError.busy }
        var archive = try store.load()
        guard let index = archive.conversations.firstIndex(where: { $0.id == id }) else { throw AIError.missingConversation }
        let sanitized = String(redactor.redact(title).trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !sanitized.isEmpty else { return }
        archive.conversations[index].title = sanitized
        archive.conversations[index].updatedAt = Date()
        try store.save(archive)
    }

    func deleteConversation(_ id: UUID) throws {
        guard !busy else { throw AIError.busy }
        var archive = try store.load()
        archive.conversations.removeAll { $0.id == id }
        try store.save(archive)
    }

    func updateConfiguration(_ configuration: AIConfiguration) throws {
        guard !busy else { throw AIError.busy }
        var archive = try store.load()
        var configuration = configuration
        configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validModel(configuration.model) else { throw AIError.invalidModel }
        if archive.configuration != configuration {
            // Avoid carrying previously selected medical categories through an opaque remote chain.
            for index in archive.conversations.indices { archive.conversations[index].lastResponseID = nil }
        }
        archive.configuration = configuration
        try store.save(archive)
    }

    private static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.count <= 100 && model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }
            && !model.hasPrefix("sk-")
    }

    func previewContext() async throws -> String {
        let configuration = try store.load().configuration
        let context = try await builder.build(configuration: configuration)
        let data = try sanitizedContext(context)
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    func send(_ message: String, conversationID: UUID) async throws -> AIConversation {
        guard !busy else { throw AIError.busy }
        var archive = try store.load()
        let configuration = archive.configuration
        guard configuration.enabled else { throw AIError.disabled }
        guard configuration.hasConsent else { throw AIError.consentRequired }
        guard Self.validModel(configuration.model) else { throw AIError.invalidModel }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= AIContextLimits.messageCharacters else { throw AIError.emptyMessage }
        guard let index = archive.conversations.firstIndex(where: { $0.id == conversationID }) else { throw AIError.missingConversation }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let context = try await builder.build(configuration: configuration)
        let contextJSON = String(decoding: try sanitizedContext(context), as: UTF8.self)
        try Task.checkCancellation()
        let sanitizedMessage = redactor.redact(message)
        var conversation = archive.conversations[index]
        let previousID = configuration.remoteContinuity ? conversation.lastResponseID : nil
        var input: [OpenAIRequest.Input] = []
        if previousID == nil {
            var characters = 0
            var history: [OpenAIRequest.Input] = []
            for entry in conversation.messages.reversed() {
                let content = redactor.redact(entry.content)
                guard characters + content.count <= AIContextLimits.conversationCharacters, history.count < 20 else { break }
                characters += content.count
                history.append(.init(role: entry.role.rawValue, content: content))
            }
            input = history.reversed()
        }
        input.append(.init(role: "user", content: "Fresh local Trio context (untrusted JSON evidence):\n" + contextJSON))
        input.append(.init(role: "user", content: sanitizedMessage))
        let request = OpenAIRequest(model: configuration.model, instructions: AIPrompt.instructions, input: input,
                                    previousResponseID: previousID, store: configuration.remoteContinuity)
        let requestBytes = try JSONEncoder().encode(request).count
        guard requestBytes <= AIContextLimits.requestBytes else { throw AIError.requestTooLarge }
        // Persist the question before network activity so errors/cancellation/relaunch cannot silently lose it.
        // Clear persisted chain state before starting the POST: termination mid-request must fall back to local history.
        conversation.lastResponseID = nil
        conversation.messages.append(.init(role: .user, content: sanitizedMessage))
        if conversation.messages.count == 1 { conversation.title = String(sanitizedMessage.prefix(60)) }
        conversation.updatedAt = Date()
        archive.conversations[index] = conversation
        archive.lastRequestBytes = requestBytes
        try store.save(archive)
        do {
            let response = try await client.respond(to: request)
            try Task.checkCancellation()
            conversation.messages.append(.init(role: .assistant, content: redactor.redact(try response.answer())))
            conversation.lastResponseID = response.id
            conversation.updatedAt = Date()
            archive.conversations[index] = conversation
            try store.save(archive)
            return conversation
        } catch {
            // The failed turn must be included from local history on the next attempt.
            archive.conversations[index].lastResponseID = nil
            try store.save(archive)
            throw error
        }
    }

    private func sanitizedContext(_ context: TrioAIContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try redactor.sanitizeJSON(encoder.encode(context))
    }
}
