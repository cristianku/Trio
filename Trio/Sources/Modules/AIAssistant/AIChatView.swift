import SwiftUI

struct AIChatView: View {
    @Bindable var state: AIAssistant.StateModel
    let conversationID: UUID
    var initialQuestion: String?
    @FocusState private var isComposerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private var visibleMessages: [AIMessage] {
        let messages = state.conversation(conversationID)?.messages ?? []
        // The graph button supplies the first question; only hide that automatic turn.
        if let initialQuestion, messages.first?.role == .user, messages.first?.content == initialQuestion {
            return Array(messages.dropFirst())
        }
        return messages
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text("Experimental • Explanations only • Cannot change therapy")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(visibleMessages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(message.role == .user ? String(localized: "You") : String(localized: "AI Assistant"))
                                        .font(.headline)
                                    Spacer()
                                    Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(AIMessageFormatting.content(message)).textSelection(.enabled)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == .user ? Color.accentColor.opacity(0.1) : Color.chart)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        if state.isLoading { ProgressView("Reading selected data and preparing an explanation…") }
                        if let error = state.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
                        Color.clear.frame(height: 1).id("newest")
                    }.padding()
                }
                .onChange(of: state.conversation(conversationID)?.messages.count) {
                    if state.conversation(conversationID)?.messages.last?.role == .assistant {
                        isComposerFocused = false
                    }
                    withAnimation { proxy.scrollTo("newest", anchor: .bottom) } }
                .onChange(of: state.isLoading) { withAnimation { proxy.scrollTo("newest", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("newest", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !state.configuration.enabled || !state.configuration.hasConsent || !state.hasKey {
                    NavigationLink("Set up AI") { AISettingsView(state: state) }
                }
                TextField(
                    "Ask about your Trio data",
                    text: Binding(get: { state.draft(for: conversationID) }, set: { state.setDraft($0, for: conversationID) }),
                    axis: .vertical
                )
                .lineLimit(2 ... 6)
                .textFieldStyle(.roundedBorder)
                .focused($isComposerFocused)
                .disabled(state.isLoading)
                HStack {
                    Text("Up to 7 days of history").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if state.isLoading {
                        Button("Cancel", role: .cancel) { state.cancel() }
                    } else {
                        Button("Send", systemImage: "arrow.up.circle.fill") { state.send(conversationID: conversationID) }
                            .disabled(
                                !state.isReady || !state.configuration.enabled || !state.configuration.hasConsent || !state
                                    .hasKey ||
                                    state.draft(for: conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty || state
                                    .draft(for: conversationID).count > AIContextLimits.messageCharacters
                            )
                    }
                }
            }.padding().background(Color.chart)
        }
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(
            initialQuestion != nil ? String(localized: "Chart") :
                state.conversation(conversationID)?.displayTitle ?? String(localized: "AI Chat")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            NavigationLink(destination: AISettingsView(state: state)) { Image(systemName: "gearshape") }
                .disabled(state.isLoading) }
        .onDisappear { state.cancel() }
    }
}

enum AIMessageFormatting {
    static func content(_ message: AIMessage) -> AttributedString {
        guard message.role == .assistant,
              let parsed = try? AttributedString(
                  markdown: message.content,
                  options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)
              )
        else { return AttributedString(message.content) }

        // Copy text and inline styling only: never retain link, image or custom attributes from model output.
        var result = AttributedString()
        for run in parsed.runs {
            var text = AttributedString(String(parsed[run.range].characters))
            text.inlinePresentationIntent = run.inlinePresentationIntent?.intersection([.emphasized, .stronglyEmphasized, .code])
            result += text
        }
        return result
    }
}
