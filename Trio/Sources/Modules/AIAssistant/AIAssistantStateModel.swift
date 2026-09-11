import Foundation
import Observation

extension AIAssistant {
    @Observable @MainActor final class StateModel {
        private let provider: Provider
        var conversations: [AIConversation] = []
        var configuration = AIConfiguration()
        var lastRequestBytes: Int?
        var errorMessage: String?
        var isLoading = false
        var isPreviewing = false
        var isReady = false
        private(set) var keyPreview: String?
        var hasKey: Bool { keyPreview != nil }
        private var drafts: [UUID: String] = [:]
        var preview = ""
        private var requestTask: Task<Void, Never>?
        private var previewTask: Task<Void, Never>?

        init(provider: Provider) {
            self.provider = provider
            reload()
        }

        func reload() {
            do {
                let archive = try provider.service.load()
                configuration = archive.configuration
                conversations = archive.conversations.sorted { $0.updatedAt > $1.updatedAt }
                lastRequestBytes = archive.lastRequestBytes
                keyPreview = try? provider.credentials.maskedAPIKey()
                isReady = true
            } catch { isReady = false; report(error) }
        }

        func conversation(_ id: UUID) -> AIConversation? { conversations.first { $0.id == id } }

        func newConversation() -> UUID? {
            do {
                let conversation = try provider.service.newConversation()
                reload()
                return conversation.id
            } catch { report(error); return nil }
        }

        func rename(_ id: UUID, title: String) {
            do { try provider.service.renameConversation(id, title: title); reload() } catch { report(error) }
        }

        func delete(_ id: UUID) {
            do { try provider.service.deleteConversation(id); reload() } catch { report(error) }
        }

        func saveConfiguration() {
            do { try provider.service.updateConfiguration(configuration); reload() } catch { report(error); reload() }
        }

        func acceptConsent() {
            configuration.consentVersion = AIPrompt.consentVersion
            saveConfiguration()
        }

        @discardableResult func replaceKey(_ key: String) -> Bool {
            do {
                try provider.credentials.replaceKey(key)
                keyPreview = try provider.credentials.maskedAPIKey()
                errorMessage = nil
                return true
            } catch { report(error); return false }
        }

        func previewContext() {
            guard !isPreviewing else { return }
            isPreviewing = true
            preview = ""
            previewTask = Task { [weak self] in
                guard let self else { return }
                defer { isPreviewing = false; previewTask = nil }
                do { preview = try await provider.service.previewContext() } catch { report(error) }
            }
        }

        func draft(for id: UUID) -> String { drafts[id] ?? "" }

        func setDraft(_ value: String, for id: UUID) { drafts[id] = value }

        func send(conversationID: UUID) {
            guard !isLoading else { return }
            let question = draft(for: conversationID)
            let originalMessageCount = conversation(conversationID)?.messages.count ?? 0
            errorMessage = nil
            isLoading = true
            requestTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    isLoading = false
                    requestTask = nil
                    reload()
                    // Clear only after the question was saved. Collection failures retain the draft for retry.
                    if (conversation(conversationID)?.messages.count ?? 0) > originalMessageCount { drafts[conversationID] = nil }
                }
                do { _ = try await provider.service.send(question, conversationID: conversationID) }
                catch is CancellationError { errorMessage = "Request cancelled. Any saved question remains in this conversation." }
                catch { report(error) }
            }
        }

        func cancel() { requestTask?.cancel() }

        func cancelPreview() { previewTask?.cancel() }

        private func report(_ error: Error) {
            // Never show raw transport, Keychain or database error descriptions that may contain credentials.
            errorMessage = (error as? AIError)?.errorDescription ?? "AI Assistant could not complete this operation. Try again."
        }
    }
}
