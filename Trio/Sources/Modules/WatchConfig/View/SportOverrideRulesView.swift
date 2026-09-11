import SwiftUI

struct SportOverrideRulesView: View {
    @ObservedObject var state: WatchConfig.StateModel
    @State private var isAdding = false
    @State private var draftActivity: SportActivityKind?
    @State private var draftPresetID: String?
    @State private var guideRule: SportOverrideRule?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section {
                Toggle("Automatic Sport", isOn: $state.automaticSportEnabled)
            } footer: {
                Text(
                    "Link each activity to an override, then set up its automation in Shortcuts. Sport ends when the preset duration expires, not when the workout ends."
                )
            }
            Section {
                ForEach(state.sportOverrideRules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        linkRow(activity: Binding(
                            get: { rule.activity },
                            set: { activity in
                                if state.saveSportLink(id: rule.id, activity: activity, presetID: rule.overridePresetID) {
                                    guideRule = state.sportOverrideRules.first { $0.activity == activity }
                                }
                            }
                        ), presetID: Binding(
                            get: { rule.overridePresetID },
                            set: { _ = state.saveSportLink(id: rule.id, activity: rule.activity, presetID: $0) }
                        ), excluding: rule.id)
                        if let preset = state.sportPresets.first(where: { $0.id == rule.overridePresetID }) {
                            Text("Duration: \(preset.durationMinutes.formatted(.number.precision(.fractionLength(0 ... 1)))) min")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Override unavailable").font(.caption).foregroundStyle(.orange)
                        }
                        Button("Set Up Automation") { guideRule = rule }.font(.caption)
                    }
                }
                .onDelete { state.sportOverrideRules.remove(atOffsets: $0) }

                if isAdding {
                    VStack(alignment: .leading) {
                        Picker("Activity", selection: $draftActivity) {
                            Text("Choose activity").tag(SportActivityKind?.none)
                            ForEach(SportActivityKind.allCases.filter { activity in
                                !state.sportOverrideRules.contains { $0.activity == activity }
                            }) { activity in
                                Text(activity.displayName).tag(Optional(activity))
                            }
                        }
                        Picker("Override", selection: $draftPresetID) {
                            Text("Choose override").tag(String?.none)
                            ForEach(state.sportPresets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                        }
                        HStack {
                            Button("Add Link") {
                                guard let activity = draftActivity, let preset = draftPresetID,
                                      state.saveSportLink(id: nil, activity: activity, presetID: preset) else { return }
                                isAdding = false
                                guideRule = state.sportOverrideRules.first { $0.activity == activity }
                            }.disabled(draftActivity == nil || draftPresetID == nil)
                            Spacer()
                            Button("Cancel", role: .cancel) { isAdding = false }
                        }
                    }
                }
                Button {
                    draftActivity = nil
                    draftPresetID = nil
                    isAdding = true
                } label: {
                    Label("Add Link", systemImage: "plus")
                }
                .disabled(isAdding || state.sportOverrideRules.count >= SportActivityKind.allCases.count)
            } header: {
                Text("Activity → Override")
            } footer: {
                Text(
                    "Each activity can have one link. Editing or deleting a link does not change an override that is already running."
                )
            }
            if state.sportPresets.isEmpty {
                Section {
                    Text("Create an override preset with a finite, positive duration in Adjustments first.")
                }
            }
            if let error = state.sportError {
                Section { Text(error).foregroundStyle(.orange) }
            }
        }
        // Several controls share each list row. Automatic list button styling
        // makes the whole row actionable and interferes with its other controls.
        .buttonStyle(.borderless)
        .pickerStyle(.menu)
        .navigationTitle("Automatic Sport")
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .task { await state.loadSportPresets() }
        .sheet(item: $guideRule) { rule in
            NavigationStack {
                List {
                    Section {
                        Text("1. Open Shortcuts on your iPhone and create an Apple Watch Workout automation.")
                        Text(
                            "2. Select Start and the workout type matching \(rule.activity.displayName). Choose Run Immediately."
                        )
                        Text("3. Add Start Sport in Trio and select the link for \(rule.activity.displayName).")
                    }
                    Section {
                        Text(
                            "Repeat for each link. If you change an activity, update its automation: the previous link will no longer run."
                        )
                        Text(
                            "Trio cannot verify the workout filter in Shortcuts. Match it carefully to this activity. Delivery while locked or disconnected depends on iOS and must be checked on your devices."
                        )
                        Text(
                            "Use only the start trigger. Do not connect Cancel Override to the end trigger: it could cancel a manual override."
                        )
                    }
                }
                .navigationTitle("Set Up Automation")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { guideRule = nil } } }
            }
        }
    }

    @ViewBuilder private func linkRow(
        activity: Binding<SportActivityKind>,
        presetID: Binding<String>,
        excluding id: UUID
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading) { activityPicker(activity, excluding: id)
                presetPicker(presetID)
            }
        } else {
            HStack {
                activityPicker(activity, excluding: id)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                presetPicker(presetID)
            }
        }
    }

    private func activityPicker(_ activity: Binding<SportActivityKind>, excluding id: UUID) -> some View {
        Picker("Activity", selection: activity) {
            ForEach(SportActivityKind.allCases.filter { candidate in
                !state.sportOverrideRules.contains { $0.id != id && $0.activity == candidate }
            }) { candidate in Text(candidate.displayName).tag(candidate) }
        }.labelsHidden().accessibilityLabel(Text("Activity"))
    }

    private func presetPicker(_ presetID: Binding<String>) -> some View {
        Picker("Override", selection: presetID) {
            if !state.sportPresets.contains(where: { $0.id == presetID.wrappedValue }) {
                Text("Override unavailable").tag(presetID.wrappedValue)
            }
            ForEach(state.sportPresets) { preset in Text(preset.name).tag(preset.id) }
        }.labelsHidden().accessibilityLabel(Text("Override"))
    }
}
