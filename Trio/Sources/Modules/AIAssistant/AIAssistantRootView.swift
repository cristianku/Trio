import SwiftUI
import Swinject

extension AIAssistant {
    struct AboutView: View {
        @State private var state: StateModel
        @State private var detent: PresentationDetent = .medium
        @Environment(\.dismiss) private var dismiss

        init(resolver: Resolver) {
            _state = State(initialValue: StateModel(provider: Provider(resolver: resolver)))
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your Trio assistant").font(.title2.bold())
                    Text(
                        "It helps you understand the graph and your data. Ask questions in everyday language. It cannot change your therapy settings."
                    )
                    NavigationLink {
                        AISettingsView(state: state)
                            .onAppear { detent = .large }
                    } label: {
                        Text("AI Settings").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
            .navigationTitle(Text(verbatim: "Trio AI"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
        }
    }

    struct RootView: View {
        @State private var state: StateModel
        @State private var selectedChat: UUID?
        @State private var renameID: UUID?
        @State private var renameTitle = ""
        @Environment(\.dismiss) private var dismiss
        private let initialQuestion: String?
        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState

        init(resolver: Resolver, initialQuestion: String? = nil) {
            _state = State(initialValue: StateModel(provider: Provider(resolver: resolver)))
            self.initialQuestion = initialQuestion
        }

        var body: some View {
            if initialQuestion != nil {
                chartExplanation
                    .task {
                        guard selectedChat == nil, let id = state.newConversation() else { return }
                        selectedChat = id
                    }
            } else {
                conversationList
            }
        }

        private var chartExplanation: some View {
            Group {
                if let id = selectedChat, let initialQuestion {
                    AIChatView(state: state, conversationID: id, initialQuestion: initialQuestion)
                        .onAppear { state.sendInitialQuestionIfReady(initialQuestion, conversationID: id) }
                } else if let error = state.errorMessage {
                    Text(error).foregroundStyle(.red).padding()
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }

        private var conversationList: some View {
            List {
                Section {
                    NavigationLink("AI Settings") { AISettingsView(state: state) }
                    Button("New Chat", systemImage: "plus.bubble") { selectedChat = state.newConversation() }
                        .disabled(!state.isReady || state.isLoading)
                }.listRowBackground(Color.chart)
                Section("Conversations") {
                    if state.conversations.isEmpty {
                        Text("No conversations yet. AI Assistant is experimental and read-only.").foregroundStyle(.secondary)
                    }
                    ForEach(state.conversations) { conversation in
                        Button { selectedChat = conversation.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.displayTitle).foregroundStyle(.primary)
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Rename") { renameID = conversation.id
                                renameTitle = conversation.displayTitle }
                            Button("Delete Local Conversation", role: .destructive) { state.delete(conversation.id) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { state.delete(conversation.id) } }
                        .disabled(state.isLoading)
                    }
                }.listRowBackground(Color.chart)
                if let error = state.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }.listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("AI Assistant")
            .navigationDestination(item: $selectedChat) { id in AIChatView(state: state, conversationID: id) }
            .alert("Rename Conversation", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
                TextField("Title", text: $renameTitle)
                Button("Save") { if let id = renameID { state.rename(id, title: renameTitle) }
                    renameID = nil }
                Button("Cancel", role: .cancel) { renameID = nil }
            }
        }
    }
}

struct AIChartRequest: Identifiable {
    let id = UUID()
    let question: String
}

enum AIChartQuestion {
    static func make(interval: DateInterval?) -> String {
        let question =
            String(localized: "Explain this graph simply: what happened, what is happening now, and what is only a prediction?")
        guard let interval else { return question }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return question + "\n" + String(localized: "Visible period:") + " "
            + formatter.string(from: interval.start) + " – " + formatter.string(from: interval.end)
            + " (" + TimeZone.current.identifier + ")"
    }
}
