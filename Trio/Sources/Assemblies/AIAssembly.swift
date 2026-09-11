import Foundation
import Swinject

final class AIAssembly: Assembly {
    func assemble(container: Container) {
        container.register(AICredentialProvider.self) { _ in
            KeychainAICredentialProvider(keychain: BaseKeychain(synchronizable: false, accessibilityLevel: .whenUnlockedThisDeviceOnly))
        }.inObjectScope(.container)
        container.register(AIContextRedactor.self) { r in
            let credentials = r.resolve(AICredentialProvider.self)!
            let keychain = r.resolve(Keychain.self)!
            return DefaultAIContextRedactor(knownSecrets: {
                let secretResult: Result<String?, KeychainError> = keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
                let secret = (try? secretResult.get()) ?? ""
                return [try? credentials.apiKey(), secret, secret.isEmpty ? nil : secret.sha1()].compactMap { $0 }
            })
        }
        container.register(AIConversationStore.self) { _ in DiskAIConversationStore() }.inObjectScope(.container)
        container.register(AILogReader.self) { _ in
            FileAILogReader(paths: [SimpleLogReporter.logFilePrev, SimpleLogReporter.logFile].map { URL(fileURLWithPath: $0) })
        }
        container.register(AITrioDataReading.self) { r in
            // Mutable services remain confined to this composition boundary. The reader receives only a value-producing closure.
            let manager = r.resolve(SettingsManager.self)!
            let storage = r.resolve(FileStorage.self)!
            return TrioAIDataReader(makeContext: { CoreDataStack.shared.newTaskContext() }, readSettings: {
                var schedules: [AIScheduleEntry] = []
                if let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) {
                    schedules += basal.prefix(96).map { .init(kind: "basal", start: $0.start, value: $0.rate, unit: "U/hour") }
                }
                if let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) {
                    schedules += ratios.schedule.prefix(96).map { .init(kind: "carbRatio", start: $0.start, value: $0.ratio, unit: "\(ratios.units.rawValue)/U") }
                }
                if let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) {
                    schedules += isf.sensitivities.prefix(96).map { .init(kind: "ISF", start: $0.start, value: $0.sensitivity, unit: "\(isf.units.rawValue)/U") }
                }
                if let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) {
                    schedules += targets.targets.prefix(96).map { .init(kind: "target", start: $0.start, value: $0.low, upperValue: $0.high, unit: targets.units.rawValue) }
                }
                return AISettingsSnapshot(settings: manager.settings, preferences: manager.preferences, pump: manager.pumpSettings, schedules: schedules)
            })
        }
        container.register(AIContextBuilder.self) { r in
            TrioAIContextBuilder(source: r.resolve(AITrioDataReading.self)!, logs: r.resolve(AILogReader.self)!)
        }
        container.register(OpenAIClient.self) { r in
            URLSessionOpenAIClient(credentials: r.resolve(AICredentialProvider.self)!, redactor: r.resolve(AIContextRedactor.self)!)
        }
        container.register(AIService.self) { r in
            // AIService is resolved only by the main-actor UI provider.
            MainActor.assumeIsolated {
                DefaultAIService(store: r.resolve(AIConversationStore.self)!, builder: r.resolve(AIContextBuilder.self)!,
                                 redactor: r.resolve(AIContextRedactor.self)!, client: r.resolve(OpenAIClient.self)!)
            }
        }.inObjectScope(.container)
    }
}
