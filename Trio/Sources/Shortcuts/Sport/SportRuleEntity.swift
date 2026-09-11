import AppIntents
import Foundation

struct SportRuleEntity: AppEntity {
    var id: UUID
    var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sport Link"
    static var defaultQuery = SportRuleQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SportRuleQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [SportRuleEntity] {
        try await availableEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SportRuleEntity] { try await availableEntities() }

    @MainActor private func availableEntities() async throws -> [SportRuleEntity] {
        let resolver = TrioApp.resolver
        guard let settings = resolver.resolve(SettingsManager.self),
              let coordinator = resolver.resolve(SportModeCoordinator.self) else { throw SportModeError.storageFailure }
        let presets = try await coordinator.presets()
        return settings.settings.sportOverrideRules.compactMap { rule in
            guard let preset = presets.first(where: { $0.id == rule.overridePresetID }) else { return nil }
            return SportRuleEntity(id: rule.id, name: "\(rule.activity.displayName) → \(preset.name)")
        }
    }
}
