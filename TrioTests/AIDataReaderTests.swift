import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("AI read-only Core Data adapter", .serialized) struct AIDataReaderTests {
    @Test("Fetches bounded DTOs without pending writes, preserves SMB and enactment evidence") func snapshots() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await context.perform {
            for (offset, value) in [(-7200.0, 70), (-60.0, 120), (0.0, 130), (60.0, 200)] {
                let glucose = GlucoseStored(context: context)
                glucose.id = UUID()
                glucose.date = now.addingTimeInterval(offset)
                glucose.glucose = Int16(value)
            }
            let event = PumpEventStored(context: context)
            event.id = UUID().uuidString
            event.timestamp = now
            event.type = "Bolus"
            let bolus = BolusStored(context: context)
            bolus.amount = NSDecimalNumber(string: "0.2")
            bolus.isSMB = true
            event.bolus = bolus
            let carb = CarbEntryStored(context: context)
            carb.date = now
            carb.carbs = 12
            let determination = OrefDetermination(context: context)
            determination.id = UUID()
            determination.deliverAt = now
            determination.reason = "SMB suggested, not enacted"
            determination.smbToDeliver = NSDecimalNumber(string: "0.3")
            determination.enacted = false
            determination.iob = NSDecimalNumber(string: "1.2")
            determination.cob = 10
            try context.save()
        }
        let reader = TrioAIDataReader(makeContext: { stack.newTaskContext() }, readSettings: {
            AISettingsSnapshot(settings: [], preferences: [], pumpSettings: [], schedules: [])
        })
        let interval = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let glucose = try await reader.glucose(in: interval, limit: 1)
        #expect(glucose.map(\.glucoseMgDL) == [130])
        let pump = try await reader.pumpHistory(in: interval, limit: 10)
        #expect(pump.first?.isSMB == true)
        #expect(pump.first?.insulinUnits == Decimal(string: "0.2"))
        let determinations = try await reader.determinations(in: interval, limit: 10)
        #expect(determinations.first?.enacted == false)
        #expect(determinations.first?.iobUnits == Decimal(string: "1.2"))
        #expect(determinations.first?.cobGrams == 10)
        #expect(try await reader.carbs(in: interval, limit: 10).first?.grams == 12)
        await context.perform { #expect(!context.hasChanges) }
    }

    @Test("Therapy snapshot includes bolus calculator and meal adjustment settings") func therapySettings() throws {
        var settings = TrioSettings()
        settings.overrideFactor = 0.65
        settings.fattyMealFactor = 0.75
        settings.sweetMealFactor = 1.15
        let snapshot = AISettingsSnapshot(
            settings: settings,
            preferences: Preferences(),
            pump: PumpSettings(insulinActionCurve: 6, maxBolus: 5, maxBasal: 2),
            schedules: []
        )
        #expect(snapshot.settings.first { $0.name == "overrideFactor" }?.value == "0.65")
        #expect(snapshot.settings.first { $0.name == "fattyMealFactor" }?.value == "0.75")
        #expect(snapshot.settings.first { $0.name == "sweetMealFactor" }?.value == "1.15")
        #expect(snapshot.settings.contains { $0.name == "maxFat" })
        #expect(snapshot.settings.contains { $0.name == "maxProtein" })
    }

    @Test("Settings snapshot exposes useful SMB preferences with no networking fields") func settings() throws {
        var preferences = Preferences()
        preferences.enableSMBAlways = true
        preferences.maxIOB = 3
        let snapshot = AISettingsSnapshot(
            settings: TrioSettings(),
            preferences: preferences,
            pump: PumpSettings(insulinActionCurve: 6, maxBolus: 5, maxBasal: 2),
            schedules: []
        )
        #expect(snapshot.preferences.first { $0.name == "enableSMBAlways" }?.value == "true")
        #expect(snapshot.preferences.first { $0.name == "maxIOB" }?.value == "3")
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("isUploadEnabled"))
        #expect(!json.contains("cgmPluginIdentifier"))
    }
}

extension AIDataReaderTests {
    @Test("Therapy history includes overlapping adjustments, recorded TDD and pump state at window start") func therapyHistory(
    ) async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-3600)
        try await context.perform {
            let adjustment = OverrideStored(context: context)
            adjustment.enabled = true
            adjustment.indefinite = true
            adjustment.date = start.addingTimeInterval(-7200)
            adjustment.percentage = 120
            adjustment.smbIsOff = true
            let target = TempTargetRunStored(context: context)
            target.startDate = start.addingTimeInterval(-600)
            target.endDate = start.addingTimeInterval(600)
            target.target = 140
            let old = TempTargetRunStored(context: context)
            old.startDate = start.addingTimeInterval(-7200)
            old.endDate = start.addingTimeInterval(-3600)
            old.target = 180
            let tdd = TDDStored(context: context)
            tdd.id = UUID()
            tdd.date = now
            tdd.total = 42
            tdd.bolus = 20
            tdd.scheduledBasal = 12
            tdd.tempBasal = 10
            let basal = PumpEventStored(context: context)
            basal.id = UUID().uuidString
            basal.type = "TempBasal"
            basal.timestamp = start.addingTimeInterval(-600)
            let temp = TempBasalStored(context: context)
            temp.rate = 0.5
            temp.duration = 30
            basal.tempBasal = temp
            let suspend = PumpEventStored(context: context)
            suspend.id = UUID().uuidString
            suspend.type = "PumpSuspend"
            suspend.timestamp = start.addingTimeInterval(-300)
            try context.save()
        }
        let reader = TrioAIDataReader(makeContext: { stack.newTaskContext() }, readSettings: {
            AISettingsSnapshot(settings: [], preferences: [], pumpSettings: [], schedules: [])
        })
        let interval = DateInterval(start: start, end: now)
        let adjustments = try await reader.adjustments(in: interval, limit: 50)
        #expect(adjustments.count == 2)
        #expect(
            adjustments
                .contains { $0.kind == "override" && $0.parameters.contains { $0.name == "percentage" && $0.value == "120.0" } }
        )
        #expect(adjustments.contains { $0.kind == "tempTarget" && $0.targetMgDL == 140 })
        let tdd = try await reader.totalDailyDose(in: interval)
        #expect(tdd?.totalUnits == 42)
        #expect(tdd?.date == now)
        let boundary = try await reader.pumpBoundaryEvents(before: start)
        #expect(Set(boundary.map(\.type)) == ["TempBasal", "PumpSuspend"])
        #expect(boundary.first { $0.type == "TempBasal" }?.rateUnitsPerHour == 0.5)
        #expect(boundary.first { $0.type == "TempBasal" }?.insulinUnits == nil)
        var selection = AIConfiguration()
        selection.historyHours = .one
        selection.selectTherapyContext()
        let builder = TrioAIContextBuilder(source: reader, logs: EmptyAILogs(), now: { now })
        let snapshot = try await builder.build(configuration: selection)
        #expect(snapshot.adjustments.count == 2)
        #expect(snapshot.latestStoredTDD?.totalUnits == 42)
        #expect(snapshot.pumpStateBeforeInterval.count == 2)
        let noLongerOverlapping = try await reader.pumpBoundaryEvents(before: now)
        #expect(!noLongerOverlapping.contains { $0.type == "TempBasal" })
    }
}
