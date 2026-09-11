import Foundation
import Testing

@testable import Trio

@Suite("Sport override rules") struct SportOverrideRulesTests {
    @Test("Existing settings default to sport off and an empty list") func oldSettings() throws {
        let settings = try JSONDecoder().decode(TrioSettings.self, from: Data("{}".utf8))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(saved["automaticSportEnabled"] as? Bool == false)
        #expect((saved["sportOverrideRules"] as? [Any])?.isEmpty == true)
    }

    @Test("Sport mappings survive a settings round trip in their original order") func persistence() throws {
        let input = Data("""
        {"automaticSportEnabled":true,"sportOverrideRules":[
          {"id":"11111111-1111-1111-1111-111111111111","activity":"running","overridePresetID":"run"},
          {"id":"22222222-2222-2222-2222-222222222222","activity":"cycling","overridePresetID":"bike"}
        ]}
        """.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: input)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(saved["automaticSportEnabled"] as? Bool == true)
        let rows = try #require(saved["sportOverrideRules"] as? [[String: String]])
        #expect(rows.map { $0["overridePresetID"] } == ["run", "bike"])
    }
}

extension SportOverrideRulesTests {
    @Test("Editing a preset keeps identity, editing the activity invalidates old shortcuts") func editIdentity() throws {
        let rule = SportOverrideRule(activity: .running, overridePresetID: "a")
        let changedPreset = try SportOverrideRule.saving(id: rule.id, activity: .running, presetID: "b", in: [rule])
        #expect(changedPreset.count == 1 && changedPreset[0].id == rule.id)
        #expect(changedPreset[0].overridePresetID == "b")
        let changedActivity = try SportOverrideRule.saving(id: rule.id, activity: .cycling, presetID: "a", in: [rule])
        #expect(changedActivity[0].id != rule.id)
        #expect(changedActivity[0].activity == .cycling)
    }

    @Test("Duplicate activities and incomplete rows are rejected, shared presets are allowed") func duplicateActivity() throws {
        let rule = SportOverrideRule(activity: .running, overridePresetID: "a")
        #expect(throws: SportModeError.duplicateActivity) {
            try SportOverrideRule.saving(id: nil, activity: .running, presetID: "b", in: [rule])
        }
        #expect(throws: SportModeError.invalidPreset) {
            try SportOverrideRule.saving(id: nil, activity: .cycling, presetID: "", in: [rule])
        }
        let rules = try SportOverrideRule.saving(id: nil, activity: .cycling, presetID: "a", in: [rule])
        #expect(rules.count == 2)
        #expect(rules[0].id == rule.id)
    }
}
