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
        var isReady = false
        private(set) var keyPreview: String?
        var hasKey: Bool { keyPreview != nil }
        private var drafts: [UUID: String] = [:]
        private var requestTask: Task<Void, Never>?
        private var initialQuestionAttempts: Set<UUID> = []

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
            } catch { isReady = false
                report(error) }
        }

        func conversation(_ id: UUID) -> AIConversation? { conversations.first { $0.id == id } }

        func newConversation() -> UUID? {
            do {
                let conversation = try provider.service.newConversation()
                reload()
                return conversation.id
            } catch { report(error)
                return nil }
        }

        func rename(_ id: UUID, title: String) {
            do { try provider.service.renameConversation(id, title: title)
                reload() } catch { report(error) }
        }

        func delete(_ id: UUID) {
            do { try provider.service.deleteConversation(id)
                reload() } catch { report(error) }
        }

        func saveConfiguration() {
            do { try provider.service.updateConfiguration(configuration)
                reload() } catch { report(error)
                reload() }
        }

        func acceptConsent() {
            configuration.consentVersion = AIPrompt.consentVersion
            configuration.enabled = true
            configuration.categories = Set(AIContextCategory.allCases)
            configuration.automaticallySelectContext = true
            configuration.warningsOnly = true
            configuration.remoteContinuity = false
            saveConfiguration()
        }

        @discardableResult func replaceKey(_ key: String) -> Bool {
            do {
                try provider.credentials.replaceKey(key)
                keyPreview = try provider.credentials.maskedAPIKey()
                errorMessage = nil
                return true
            } catch { report(error)
                return false }
        }

        func draft(for id: UUID) -> String { drafts[id] ?? "" }

        func setDraft(_ value: String, for id: UUID) { drafts[id] = value }

        func sendInitialQuestionIfReady(_ question: String, conversationID: UUID) {
            guard isReady, configuration.enabled, configuration.hasConsent, hasKey, !isLoading,
                  conversation(conversationID)?.messages.isEmpty == true,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  initialQuestionAttempts.insert(conversationID).inserted
            else { return }
            send(question, conversationID: conversationID, clearsDraft: false)
        }

        func send(conversationID: UUID) {
            send(draft(for: conversationID), conversationID: conversationID, clearsDraft: true)
        }

        private func send(_ question: String, conversationID: UUID, clearsDraft: Bool) {
            guard !isLoading else { return }
            let originalMessageCount = conversation(conversationID)?.messages.count ?? 0
            errorMessage = nil
            isLoading = true
            requestTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    isLoading = false
                    requestTask = nil
                    reload()
                    // Automatic graph requests never use or clear the user's composer draft.
                    // Manual collection failures retain the draft for retry.
                    if clearsDraft, (conversation(conversationID)?.messages.count ?? 0) > originalMessageCount {
                        drafts[conversationID] = nil
                    }
                }
                do { _ = try await provider.service.send(question, conversationID: conversationID) }
                catch is CancellationError {
                    errorMessage = String(localized: "Request cancelled. Any saved question remains in this conversation.")
                } catch { report(error) }
            }
        }

        func cancel() { requestTask?.cancel() }

        private func report(_ error: Error) {
            // Never show raw transport, Keychain or database error descriptions that may contain credentials.
            errorMessage = (error as? AIError)?
                .errorDescription ?? String(localized: "AI Assistant could not complete this operation. Try again.")
        }
    }
}
