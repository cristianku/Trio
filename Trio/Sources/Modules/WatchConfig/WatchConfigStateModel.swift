import Combine
import ConnectIQ
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false
        @Published var automaticSportEnabled = false
        @Published var sportOverrideRules: [SportOverrideRule] = []
        @Published var sportPresets: [SportPresetChoice] = []
        @Published var sportError: String?

        @MainActor func loadSportPresets() async {
            do {
                guard let coordinator = resolver?.resolve(SportModeCoordinator.self) else { throw SportModeError.storageFailure }
                sportPresets = try await coordinator.presets()
                sportError = nil
            } catch {
                sportPresets = []
                sportError = SportModeError.storageFailure.localizedDescription
            }
        }

        @MainActor func saveSportLink(id: UUID?, activity: SportActivityKind, presetID: String) -> Bool {
            do {
                guard sportPresets.contains(where: { $0.id == presetID }) else { throw SportModeError.invalidPreset }
                sportOverrideRules = try SportOverrideRule.saving(
                    id: id,
                    activity: activity,
                    presetID: presetID,
                    in: sportOverrideRules
                )
                sportError = nil
                return true
            } catch {
                sportError = error.localizedDescription
                return false
            }
        }

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }

            subscribeSetting(\.automaticSportEnabled, on: $automaticSportEnabled) { automaticSportEnabled = $0 }
            subscribeSetting(\.sportOverrideRules, on: $sportOverrideRules) { sportOverrideRules = $0 }

            devices = garmin.devices
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
