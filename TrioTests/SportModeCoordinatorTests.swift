import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("Sport activation storage", .serialized) struct SportModeCoordinatorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Picker lists finite override presets, excluding custom overrides and temporary targets") func presetChoices() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform {
            try self.makePreset(in: context)
            let indefinite = OverrideStored(context: context)
            indefinite.id = "indefinite"
            indefinite.name = "Override1"
            indefinite.isPreset = true
            indefinite.indefinite = true
            indefinite.duration = 0
            let custom = OverrideStored(context: context)
            custom.id = "custom"
            custom.name = "Custom Override"
            custom.duration = 85
            let target = TempTargetStored(context: context)
            target.id = UUID()
            target.name = "Obiettivo_temporaneo1"
            target.isPreset = true
            target.target = 115
            target.duration = 55
            try context.save()
        }
        let coordinator = SportModeCoordinator(settings: { TrioSettings() }, makeContext: stack.newTaskContext)
        #expect(try await coordinator.presets() == [SportPresetChoice(id: "preset", name: "Running", durationMinutes: 45)])
        // A newly saved finite preset must appear on the next screen load.
        try await context.perform {
            let preset = try #require(context.fetch(OverrideStored.fetchRequest()).first { $0.id == "indefinite" })
            preset.indefinite = false
            preset.duration = 60
            try context.save()
        }
        let choices = try await coordinator.presets()
        #expect(Set(choices.map(\.id)) == ["preset", "indefinite"])
    }

    @Test("Sport creates one independent activation with unchanged parameters and finite expiry") func activationAndDuplicate(
    ) async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform { try self.makePreset(in: context) }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        #expect(try await coordinator.start(ruleID: rule.id) == .activated(until: now.addingTimeInterval(2700)))
        #expect(try await coordinator.start(ruleID: rule.id) == .alreadyActive(until: now.addingTimeInterval(2700)))
        let read = stack.newTaskContext()
        try await read.perform {
            let records = try read.fetch(OverrideStored.fetchRequest())
            #expect(records.count == 2)
            let preset = try #require(records.first { $0.id == "preset" })
            let sport = try #require(records.first { $0.sportRuleID == rule.id })
            #expect(!preset.enabled)
            #expect(sport.id != preset.id)
            #expect(UUID(uuidString: sport.id ?? "") != nil)
            #expect(sport.enabled && !sport.isPreset && !sport.indefinite)
            #expect(sport.duration == 45 && sport.percentage == 80 && sport.target == 140)
            #expect(sport.smbIsOff && sport.isf && !sport.cr && sport.advancedSettings)
            #expect(sport.smbMinutes == 12 && sport.uamMinutes == 18)
            #expect(sport.smbIsScheduledOff && sport.start == 7 && sport.end == 9)
            #expect(sport.date == self.now)
            #expect(!sport.isUploadedToNS)
        }
    }

    @Test("Manual writes retire sport atomically and canceled sport cannot restart from a duplicate") func manualPrecedence() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform { try self.makePreset(in: context) }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        _ = try await coordinator.start(ruleID: rule.id)
        try await context.perform {
            let manual = OverrideStored(context: context)
            manual.id = UUID().uuidString
            manual.name = "Manual"
            manual.date = self.now
            manual.duration = 30
            manual.enabled = true
            try context.saveWithSportPrecedence(at: self.now)
            manual.enabled = false
            try context.save()
        }
        #expect(try await coordinator.start(ruleID: rule.id) == .previouslyHandled)
        let read = stack.newTaskContext()
        try await read.perform {
            let records = try read.fetch(OverrideStored.fetchRequest())
            #expect(records.filter(\.enabled).isEmpty)
            let runs = try read.fetch(OverrideRunStored.fetchRequest())
            #expect(runs.count == 1)
            #expect(runs.first?.override?.sportRuleID == rule.id)
        }
    }

    @Test("Active manual targets block sport; future targets do not") func targetConflict() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform {
            try self.makePreset(in: context)
            let target = TempTargetStored(context: context)
            target.id = UUID()
            target.date = self.now
            target.duration = 30
            target.enabled = true
            try context.save()
        }
        let rule = SportOverrideRule(activity: .cycling, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        await #expect(throws: SportModeError.tempTargetConflict) { try await coordinator.start(ruleID: rule.id) }
        try await context.perform {
            let target = try #require(context.fetch(TempTargetStored.fetchRequest()).first)
            target.date = self.now.addingTimeInterval(3600)
            try context.save()
        }
        #expect(try await coordinator.start(ruleID: rule.id) == .activated(until: now.addingTimeInterval(2700)))
    }

    @Test("Missing presets never cancel a manual override") func missingPreset() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform {
            let manual = OverrideStored(context: context)
            manual.id = "manual"
            manual.enabled = true
            manual.date = self.now
            manual.indefinite = true
            try context.save()
        }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "deleted")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        await #expect(throws: SportModeError.invalidPreset) { try await coordinator.start(ruleID: rule.id) }
        try await context.perform {
            let records = try context.fetch(OverrideStored.fetchRequest())
            #expect(records.filter(\.enabled).count == 1)
        }
    }

    private func makePreset(in context: NSManagedObjectContext) throws {
        let preset = OverrideStored(context: context)
        preset.id = "preset"
        preset.name = "Running"
        preset.isPreset = true
        preset.duration = 45
        preset.percentage = 80
        preset.target = 140
        preset.smbIsOff = true
        preset.isf = true
        preset.cr = false
        preset.advancedSettings = true
        preset.smbMinutes = 12
        preset.uamMinutes = 18
        preset.smbIsScheduledOff = true
        preset.start = 7
        preset.end = 9
        try context.save()
    }
}

extension SportModeCoordinatorTests {
    @Test("Editing sport is manual takeover, including indefinite duration") func editedSport() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        try await context.perform { try self.makePreset(in: context) }
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        _ = try await coordinator.start(ruleID: rule.id)
        let edit = stack.newTaskContext()
        try await edit.perform {
            let sport = try #require(edit.fetch(OverrideStored.fetchRequest()).first { $0.sportRuleID != nil })
            sport.indefinite = true
            sport.percentage = 90
            try edit.saveWithSportPrecedence(at: self.now.addingTimeInterval(60))
            #expect(sport.enabled && sport.indefinite && sport.percentage == 90)
            #expect(sport.sportRuleID == nil)
            let records = try edit.fetch(OverrideStored.fetchRequest())
            let tombstone = try #require(records.first { $0.sportRuleID == rule.id })
            #expect(!tombstone.enabled && !tombstone.indefinite && tombstone.duration == 45)
            #expect(tombstone.overrideRun?.endDate == self.now.addingTimeInterval(60))
        }
    }

    @Test("Concurrent starts create a single sport activation") func concurrentStarts() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform { try self.makePreset(in: context) }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        let results = try await withThrowingTaskGroup(of: SportActivationResult.self) { group in
            for _ in 0 ..< 6 { group.addTask { try await coordinator.start(ruleID: rule.id) } }
            var results: [SportActivationResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.filter { if case .activated = $0 { return true }
            return false }.count == 1)
        #expect(results.filter { if case .alreadyActive = $0 { return true }
            return false }.count == 5)
    }
}

extension SportModeCoordinatorTests {
    @Test("Starting sport closes expired overrides at their actual end") func closesExpiredRows() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform {
            try self.makePreset(in: context)
            let expired = OverrideStored(context: context)
            expired.id = "expired"
            expired.enabled = true
            expired.date = self.now.addingTimeInterval(-3600)
            expired.duration = 10
            try context.save()
        }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        _ = try await coordinator.start(ruleID: rule.id)
        let read = stack.newTaskContext()
        try await read.perform {
            let expired = try #require(read.fetch(OverrideStored.fetchRequest()).first { $0.id == "expired" })
            #expect(!expired.enabled)
            #expect(expired.overrideRun?.endDate == self.now.addingTimeInterval(-3000))
        }
    }

    @Test("A failed save leaves the preset and existing records untouched") func failedSave() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform { try self.makePreset(in: context) }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: {
            let failing = SportFailingSaveContext(concurrencyType: .privateQueueConcurrencyType)
            failing.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
            return failing
        }, now: { now })
        await #expect(throws: SportTestSaveError.failed) { try await coordinator.start(ruleID: rule.id) }
        let read = stack.newTaskContext()
        try await read.perform {
            let records = try read.fetch(OverrideStored.fetchRequest())
            #expect(records.count == 1 && records[0].isPreset && !records[0].enabled)
            #expect(records[0].sportRuleID == nil)
        }
    }

    @Test("Extending an expired target retires sport, saving a future target does not") func editedTarget() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform { try self.makePreset(in: context) }
        let rule = SportOverrideRule(activity: .running, overridePresetID: "preset")
        var settings = TrioSettings()
        settings.automaticSportEnabled = true
        settings.sportOverrideRules = [rule]
        let coordinator = SportModeCoordinator(settings: { settings }, makeContext: stack.newTaskContext, now: { now })
        _ = try await coordinator.start(ruleID: rule.id)
        let edit = stack.newTaskContext()
        try await edit.perform {
            let target = TempTargetStored(context: edit)
            target.id = UUID()
            target.date = self.now.addingTimeInterval(3600)
            target.duration = 30
            target.enabled = true
            try edit.saveWithSportPrecedence(at: self.now)
            let sport = try #require(edit.fetch(OverrideStored.fetchRequest()).first { $0.sportRuleID != nil })
            #expect(sport.enabled)
            target.date = self.now.addingTimeInterval(-3600)
            target.duration = 120
            try edit.saveWithSportPrecedence(at: self.now)
            #expect(!sport.enabled)
            #expect(sport.overrideRun?.endDate == self.now)
        }
    }
}

private enum SportTestSaveError: Error { case failed }
private final class SportFailingSaveContext: NSManagedObjectContext {
    override func save() throws { throw SportTestSaveError.failed }
}
