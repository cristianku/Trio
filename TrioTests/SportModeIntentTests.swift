import Foundation
import Testing

@testable import Trio

@Suite("Sport shortcut resolution") struct SportModeIntentTests {
    @Test("Saved shortcut resolves current rules instead of trusting its cached preset") func resolve() throws {
        let rule = SportOverrideRule(activity: .running, overridePresetID: "old")
        let entity = SportRuleEntity(id: rule.id, name: "Cached name")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [SportOverrideRule(id: rule.id, activity: .running, overridePresetID: "new")]
        #expect(try SportModeCoordinator.resolveRule(id: entity.id, settings: settings).overridePresetID == "new")
        settings.sportOverrideRules = []
        #expect(throws: SportModeError.ruleUnavailable) { try SportModeCoordinator.resolveRule(id: entity.id, settings: settings)
        }
    }

    @Test("Disabled and invalid shortcut rules cannot resolve an override") func disabled() throws {
        var settings = TrioSettings()
        let rule = SportOverrideRule(activity: .cycling, overridePresetID: "b")
        settings.sportOverrideRules = [rule]
        #expect(throws: SportModeError.disabled) { try SportModeCoordinator.resolveRule(id: rule.id, settings: settings) }
        settings.automaticSportEnabled = true
        settings.sportOverrideRules.append(SportOverrideRule(activity: .cycling, overridePresetID: "other"))
        #expect(throws: SportModeError.duplicateActivity) { try SportModeCoordinator.resolveRule(id: rule.id, settings: settings)
        }
    }
}
