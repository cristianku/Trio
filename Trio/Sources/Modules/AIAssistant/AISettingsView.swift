import SwiftUI

struct AISettingsView: View {
    @Bindable var state: AIAssistant.StateModel
    @State private var replacementKey = ""
    @State private var model = ""
    @State private var showConsent = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Assistant", isOn: setting(\.enabled))
                Button(state.configuration.hasConsent ? "Review Data Sharing Consent" : "Review and Accept Data Sharing") { showConsent = true }
            } footer: {
                Text("Read-only and experimental. Selected medical data and conversation messages are sent to OpenAI only when you press Send.")
            }.listRowBackground(Color.chart)
            Section("OpenAI API Key") {
                Text(state.hasKey ? "Key saved in Keychain" : "No key saved").foregroundStyle(.secondary)
                SecureField("New or replacement API key", text: $replacementKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive()
                Button("Save / Replace Key") { state.replaceKey(replacementKey); replacementKey = "" }.disabled(replacementKey.isEmpty)
                Button("Delete Key", role: .destructive) { state.deleteKey(); replacementKey = "" }.disabled(!state.hasKey)
                TextField("Model ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Model") { state.configuration.model = model; state.saveConfiguration(); model = state.configuration.model }
            }.listRowBackground(Color.chart)
            Section("Context for Each Message") {
                Button("Select Therapy Context") {
                    state.configuration.selectTherapyContext()
                    state.saveConfiguration()
                }
                Text("Selects therapy settings, glucose, recorded insulin, carbs, determinations, overrides and temporary targets. Logs remain optional.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("History Window", selection: setting(\.historyHours)) {
                    ForEach(AIHistoryWindow.allCases) { window in Text("\(window.rawValue) hours").tag(window) }
                }
                ForEach(AIContextCategory.allCases) { category in
                    Toggle("Include \(category.title)", isOn: Binding(get: {
                        state.configuration.categories.contains(category)
                    }, set: { included in
                        if included { state.configuration.categories.insert(category) } else { state.configuration.categories.remove(category) }
                        state.saveConfiguration()
                    }))
                }
                if state.configuration.categories.contains(.logs) { Toggle("Only WARN / ERR Logs", isOn: setting(\.warningsOnly)) }
                NavigationLink("Preview AI Context") { AIContextPreviewView(state: state) }
            }.listRowBackground(Color.chart)
            Section {
                Toggle("Remote Conversation Continuity", isOn: setting(\.remoteContinuity))
            } header: { Text("Optional OpenAI Storage") } footer: {
                Text("Off by default. Enabling this requests storage of responses with OpenAI and uses previous response IDs. Local deletion does not delete remote data. Privacy changes start a new remote chain; previous local messages can still contain earlier shared facts.")
            }.listRowBackground(Color.chart)
            if let size = state.lastRequestBytes {
                Section { Text("Last request: approximately \(size) bytes").font(.caption) }.listRowBackground(Color.chart)
            }
            if let error = state.errorMessage { Section { Text(error).foregroundStyle(.red) }.listRowBackground(Color.chart) }
        }
        .disabled(state.isLoading || !state.isReady)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("AI Settings")
        .onAppear { model = state.configuration.model }
        .onDisappear { replacementKey = "" }
        .sheet(isPresented: $showConsent) {
            NavigationStack {
                ScrollView { Text(AIPrompt.consent).padding() }
                    .navigationTitle("Data Sharing")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { showConsent = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("I Agree") { state.acceptConsent(); showConsent = false } }
                    }
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AIConfiguration, Value>) -> Binding<Value> {
        Binding(get: { state.configuration[keyPath: keyPath] }, set: {
            state.configuration[keyPath: keyPath] = $0
            state.saveConfiguration()
        })
    }
}

struct AIContextPreviewView: View {
    @Bindable var state: AIAssistant.StateModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sanitized local snapshot. No request is sent by this preview. Your question and recent conversation messages will also be sent when you press Send.")
                    .font(.callout).foregroundStyle(.secondary)
                if state.isPreviewing { ProgressView("Reading context…") }
                Text(verbatim: state.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let error = state.errorMessage { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle("Preview AI Context")
        .onAppear { state.previewContext() }
        .onDisappear { state.cancelPreview(); state.preview = "" }
        .toolbar { Button("Refresh") { state.previewContext() }.disabled(state.isPreviewing) }
    }
}
