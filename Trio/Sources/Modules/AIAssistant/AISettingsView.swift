import SwiftUI

struct AISettingsView: View {
    @Bindable var state: AIAssistant.StateModel
    @State private var replacementKey = ""
    @State private var isEditingKey = false
    @State private var model = ""
    @State private var showCustomModel = false
    @State private var showConsent = false
    @FocusState private var focusedField: Field?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private enum Field: Hashable { case key, model }

    private let models: [(id: String, name: String)] = [
        ("gpt-4.1-mini", "GPT-4.1 Mini"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-6-astra", "GPT-6 Astra")
    ]

    private var modelSelection: Binding<String> {
        Binding(get: {
            !showCustomModel && models.contains { $0.id == state.configuration.model } ? state.configuration.model : "custom"
        }, set: { selection in
            guard selection != "custom" else { model = state.configuration.model; showCustomModel = true; return }
            state.configuration.model = selection
            state.saveConfiguration()
            model = state.configuration.model
            showCustomModel = false
            focusedField = nil
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Assistant", isOn: setting(\.enabled))
                Button(state.configuration.hasConsent ? "Review Data Sharing Consent" : "Review and Accept Data Sharing") { showConsent = true }
            } footer: {
                Text("Read-only and experimental. Selected medical data and conversation messages are sent to OpenAI only when you press Send.")
            }.listRowBackground(Color.chart)
            keySection
            modelSection
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
        .onChange(of: focusedField) { oldField, _ in
            if oldField == .key { savePendingKey() }
            if oldField == .model { savePendingModel() }
        }
        .onDisappear {
            savePendingKey()
            savePendingModel()
            replacementKey = ""
        }
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

    private var keySection: some View {
        Section("OpenAI API Key") {
            if let preview = state.keyPreview, !isEditingKey {
                Button {
                    replacementKey = ""
                    isEditingKey = true
                } label: {
                    HStack {
                        Text(verbatim: preview).monospaced()
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("API key, \(preview)")
                .accessibilityHint("Double tap to enter a replacement key")
                .privacySensitive()
            } else {
                SecureField("API key", text: $replacementKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .key)
                    .privacySensitive()
                    .onAppear { if isEditingKey { focusedField = .key } }
                    .onSubmit {
                        savePendingKey()
                        focusedField = nil
                    }
            }
        }.listRowBackground(Color.chart)
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: modelSelection) {
                ForEach(models, id: \.id) { option in Text(option.name).tag(option.id) }
                Text("Custom Model").tag("custom")
            }
            if showCustomModel || !models.contains(where: { $0.id == state.configuration.model }) {
                TextField("Model ID", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focusedField, equals: .model)
                    .onSubmit {
                        savePendingModel()
                        focusedField = nil
                    }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Model availability depends on your OpenAI project. Pricing varies by model.")
        }.listRowBackground(Color.chart)
    }

    private func savePendingKey() {
        guard !replacementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            replacementKey = ""
            isEditingKey = false
            return
        }
        if state.replaceKey(replacementKey) {
            replacementKey = ""
            isEditingKey = false
        }
    }

    private func savePendingModel() {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value != state.configuration.model {
            state.configuration.model = value
            state.saveConfiguration()
        }
        model = state.configuration.model
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
