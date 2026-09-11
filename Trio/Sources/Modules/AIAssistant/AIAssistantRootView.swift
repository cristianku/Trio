import SwiftUI
import Swinject

extension AIAssistant {
    struct RootView: View {
        @State private var state: StateModel
        @State private var selectedChat: UUID?
        @State private var renameID: UUID?
        @State private var renameTitle = ""
        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState

        init(resolver: Resolver) {
            _state = State(initialValue: StateModel(provider: Provider(resolver: resolver)))
        }

        var body: some View {
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
                                Text(conversation.title).foregroundStyle(.primary)
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Rename") { renameID = conversation.id; renameTitle = conversation.title }
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
                Button("Save") { if let id = renameID { state.rename(id, title: renameTitle) }; renameID = nil }
                Button("Cancel", role: .cancel) { renameID = nil }
            }
        }
    }
}
