import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("Sport override expiry", .serialized) struct SportExpiryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Sport expires at its duration in minutes without a Home view") func sportExpiry() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let sport = self.makeOverride(context, sport: true)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [], now: self.now) === sport)
            #expect(OpenAPS.selectOverrideForAPS(
                overrides: [sport], tempTargets: [], now: self.now.addingTimeInterval(60 * 30 - 1)
            ) === sport)
            #expect(OpenAPS.selectOverrideForAPS(
                overrides: [sport], tempTargets: [], now: self.now.addingTimeInterval(60 * 30)
            ) == nil)
            #expect(sport.enabled)
        }
    }

    @Test("Future, indefinite, disabled, and malformed sport records cannot dose") func invalidSport() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let sport = self.makeOverride(context, sport: true)
            #expect(OpenAPS.selectOverrideForAPS(
                overrides: [sport], tempTargets: [], now: self.now.addingTimeInterval(-1)
            ) == nil)
            sport.indefinite = true
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [], now: self.now) == nil)
            sport.indefinite = false
            let invalidDurations: [NSDecimalNumber?] = [nil, 0, -1, .notANumber]
            for duration in invalidDurations {
                sport.duration = duration
                #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [], now: self.now) == nil)
            }
            sport.duration = 30
            sport.date = nil
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [], now: self.now) == nil)
            sport.date = self.now
            sport.enabled = false
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [], now: self.now) == nil)
        }
    }

    @Test("An effective manual override wins even if sport is newer") func manualOverrideWins() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let sport = self.makeOverride(context, sport: true)
            let manual = self.makeOverride(context, sport: false)
            manual.date = self.now.addingTimeInterval(-60)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport, manual], tempTargets: [], now: self.now) === manual)
            manual.indefinite = true
            manual.date = self.now.addingTimeInterval(-86400 * 2)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport, manual], tempTargets: [], now: self.now) === manual)
            manual.enabled = false
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport, manual], tempTargets: [], now: self.now) === sport)
        }
    }

    @Test("A current temporary target suppresses sport; expired and future targets do not") func temporaryTargetWins() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let sport = self.makeOverride(context, sport: true)
            let target = TempTargetStored(context: context)
            target.enabled = true
            target.date = self.now
            target.duration = 10
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [target], now: self.now) == nil)
            #expect(OpenAPS.selectOverrideForAPS(
                overrides: [sport], tempTargets: [target], now: self.now.addingTimeInterval(600)
            ) === sport)
            target.date = self.now.addingTimeInterval(60)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport], tempTargets: [target], now: self.now) === sport)
        }
    }

    @Test("Without sport the existing latest-override behavior is preserved") func legacySelection() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let manual = self.makeOverride(context, sport: false)
            manual.date = self.now.addingTimeInterval(-3600)
            let target = TempTargetStored(context: context)
            target.enabled = true
            target.date = self.now
            target.duration = 10
            #expect(OpenAPS.selectOverrideForAPS(overrides: [manual], tempTargets: [target], now: self.now) === manual)
        }
    }

    @Test("Expired sport never reveals an older expired manual override") func expiredSportDoesNotRestoreExpiredManual() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        await context.perform {
            let sport = self.makeOverride(context, sport: true)
            sport.date = self.now.addingTimeInterval(-3600)
            let manual = self.makeOverride(context, sport: false)
            manual.date = self.now.addingTimeInterval(-7200)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport, manual], tempTargets: [], now: self.now) == nil)
            #expect(sport.enabled && manual.enabled)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [manual], tempTargets: [], now: self.now) === manual)

            // A finite manual override lasting more than a day can still be active.
            manual.date = self.now.addingTimeInterval(-25 * 3600)
            manual.duration = NSDecimalNumber(value: 48 * 60)
            #expect(OpenAPS.selectOverrideForAPS(overrides: [sport, manual], tempTargets: [], now: self.now) === manual)
        }
    }

    private func makeOverride(_ context: NSManagedObjectContext, sport: Bool) -> OverrideStored {
        let record = OverrideStored(context: context)
        record.id = UUID().uuidString
        record.date = now
        record.duration = 30
        record.enabled = true
        record.indefinite = false
        record.sportRuleID = sport ? UUID() : nil
        return record
    }
}
