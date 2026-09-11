import Foundation
import Testing

@testable import Trio

@Suite("AI context and logs") struct AIContextTests {
    @Test("Summary boundaries do not double count meals, FPU, external insulin or pump records")
    func summaryBoundaries() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let boundary = now.addingTimeInterval(-24 * 3600)
        let pump: [AIPumpEvent] = [
            .init(date: boundary, type: "Bolus", insulinUnits: 1, rateUnitsPerHour: nil, durationMinutes: nil, isSMB: false, isExternal: false),
            .init(date: boundary, type: "Bolus", insulinUnits: 2, rateUnitsPerHour: nil, durationMinutes: nil, isSMB: false, isExternal: true),
            .init(date: boundary, type: "TempBasal", insulinUnits: nil, rateUnitsPerHour: 3, durationMinutes: 30, isSMB: nil, isExternal: nil)
        ]
        let carbs: [AICarbEntry] = [
            .init(date: boundary, grams: 20, fatGrams: 0, proteinGrams: 0, isFPU: false),
            .init(date: boundary, grams: 10, fatGrams: 0, proteinGrams: 0, isFPU: true)
        ]
        let source = ContextSourceFixture(now: now, pumpEntries: pump, carbEntries: carbs)
        let builder = TrioAIContextBuilder(source: source, logs: EmptyAILogs(), now: { now })
        var configuration = AIConfiguration()
        configuration.categories = [.pumpHistory, .carbs]
        configuration.historyHours = .twoDays
        let context = try await builder.build(configuration: configuration)
        let summaries = try #require(context.hourlySummaries)
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.pump?.recordedPumpBolusUnits == 1)
        #expect(summary.pump?.recordedExternalInsulinUnits == 2)
        #expect(summary.pump?.eventCounts["TempBasal"] == 1)
        #expect(summary.carbs?.recordedMealGrams == 20)
        #expect(summary.carbs?.recordedFPUGrams == 10)
        #expect(summary.carbs?.count == 2)
    }

    @Test("Summary fetch caps report incomplete coverage")
    func summaryTruncation() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let entry = AIGlucose(date: now.addingTimeInterval(-60), glucoseMgDL: 100, smoothedGlucoseMgDL: nil,
                             direction: nil, isManual: false)
        let source = ContextSourceFixture(now: now, glucoseEntries: Array(repeating: entry, count: 2001))
        let builder = TrioAIContextBuilder(source: source, logs: EmptyAILogs(), now: { now })
        var configuration = AIConfiguration()
        configuration.categories = [.glucose]
        configuration.historyHours = .twoDays
        let context = try await builder.build(configuration: configuration)
        #expect(context.notes.contains { $0.contains("glucose summary fetch truncated") })
        #expect(context.hourlySummaries?.compactMap(\.glucose).reduce(0) { $0 + $1.count } == 2000)
    }

    @Test("Seven-day summaries cover old and recent hours without sending raw glucose rows")
    func weekSummary() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let start = now.addingTimeInterval(-168 * 3600)
        let entries = (0..<168).map { hour in
            AIGlucose(date: start.addingTimeInterval(Double(hour) * 3600 + 60), glucoseMgDL: 80 + hour,
                      smoothedGlucoseMgDL: nil, direction: nil, isManual: false)
        }
        let builder = TrioAIContextBuilder(source: ContextSourceFixture(now: now, glucoseEntries: entries), logs: EmptyAILogs(), now: { now })
        var configuration = AIConfiguration()
        configuration.categories = [.glucose]
        configuration.historyHours = .sevenDays
        let context = try await builder.build(configuration: configuration)
        let summaries = try #require(context.hourlySummaries)
        #expect(context.glucose.isEmpty)
        #expect(context.intervalEnd == now)
        #expect(summaries.compactMap(\.glucose).reduce(0) { $0 + $1.count } == 168)
        #expect(summaries.first?.glucose?.minimumMgDL == 80)
        #expect(summaries.last?.glucose?.maximumMgDL == 247)
        #expect(summaries.allSatisfy { $0.pump == nil && $0.carbs == nil && $0.determinations == nil })
        #expect(try JSONEncoder().encode(context).count < 100000)
    }

    @Test("An older requested interval excludes current readings")
    func historicalInterval() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let builder = TrioAIContextBuilder(source: ContextSourceFixture(now: now), logs: EmptyAILogs(), now: { now })
        var configuration = AIConfiguration()
        configuration.categories = [.glucose]
        let interval = DateInterval(start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-90 * 60))
        let context = try await builder.build(configuration: configuration, interval: interval)
        #expect(context.glucose.map(\.glucoseMgDL) == [80])
        #expect(context.intervalStart == interval.start)
        #expect(context.intervalEnd == interval.end)
        #expect(context.generatedAt == now)
    }

    @Test("History is a moving selection, not the start of locally stored records")
    func rollingHistory() async throws {
        let firstDate = Date(timeIntervalSince1970: 1800000000)
        var currentDate = firstDate
        let builder = TrioAIContextBuilder(source: ContextSourceFixture(now: firstDate), logs: EmptyAILogs(), now: { currentDate })
        var config = AIConfiguration()
        config.categories = [.glucose]
        let first = try await builder.build(configuration: config)
        currentDate = firstDate.addingTimeInterval(8 * 60)
        let second = try await builder.build(configuration: config)
        #expect(second.intervalStart.timeIntervalSince(first.intervalStart) == 8 * 60)
        #expect(first.generatedAt.timeIntervalSince(first.intervalStart) == 6 * 3600)
        #expect(try #require(second.glucose.last).date > second.intervalStart)
        #expect(second.notes.contains { $0.contains("Selected history window: 6.0 hours") })
        config.historyHours = .twentyFour
        let expanded = try await builder.build(configuration: config)
        #expect(expanded.generatedAt.timeIntervalSince(expanded.intervalStart) == 24 * 3600)
        #expect(expanded.notes.contains { $0.contains("Selected history window: 24.0 hours") })
    }

    @Test("Therapy selection includes settings and both glucose and insulin history without enabling sharing")
    func therapySelection() {
        var config = AIConfiguration()
        config.selectTherapyContext()
        #expect(config.categories == [.settings, .glucose, .pumpHistory, .carbs, .determinations, .adjustments])
        #expect(!config.categories.contains(.logs))
        #expect(!config.enabled)
        #expect(!config.hasConsent)
    }

    @Test("Time window excludes old and future entries and retains newest values") func interval() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let source = ContextSourceFixture(now: now)
        let builder = TrioAIContextBuilder(source: source, logs: EmptyAILogs(), now: { now }, limits: .init(glucose: 2))
        var config = AIConfiguration()
        config.categories = [.glucose]
        config.historyHours = .one
        let context = try await builder.build(configuration: config)
        #expect(context.glucose.map(\.glucoseMgDL) == [140, 130])
        #expect(context.intervalStart == Date(timeIntervalSince1970: 1799996400))
        #expect(context.configuration == nil)
        #expect(context.pumpHistory.isEmpty)
        #expect(context.notes.contains { $0.contains("glucose") && $0.contains("truncated") })
    }

    @Test("Disabled categories do not fetch or leak data") func excluded() async throws {
        let builder = TrioAIContextBuilder(source: FailingAISource(), logs: EmptyAILogs())
        let context = try await builder.build(configuration: AIConfiguration())
        #expect(context.configuration == nil)
        #expect(context.glucose.isEmpty)
        #expect(context.logs.isEmpty)
    }

    @Test("Rotated logs respect cutoff, category, severity and UTF8 size") func logs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = folder.appendingPathComponent("log_prev.txt")
        let current = folder.appendingPathComponent("log.txt")
        try Data("2026-09-10T23:59:00+0000 [OpenAPS] a - WARN: old\n".utf8).write(to: previous)
        let content = """
        2026-09-11T01:00:00+0000 [OpenAPS] a - INFO: normal
        2026-09-11T02:00:00+0000 [Nightscout] a - ERR: other
        2026-09-11T03:00:00+0000 [OpenAPS] a - WARN: recent é
        continuation without timestamp
        2026-09-11T04:00:00+0000 [OpenAPS] a - ERR: newest
        
        """
        try Data(content.utf8).write(to: current)
        let reader = FileAILogReader(paths: [previous, current])
        let formatter = ISO8601DateFormatter()
        let entries = try await reader.read(
            interval: DateInterval(start: formatter.date(from: "2026-09-11T00:00:00Z")!, end: formatter.date(from: "2026-09-11T05:00:00Z")!),
            categories: ["OpenAPS"], warningsOnly: true, maxBytes: 1000
        )
        #expect(entries.count == 2)
        #expect(entries.first?.message.contains("newest") == true)
        #expect(entries.last?.message.contains("recent é") == true)
        #expect(!entries.contains { $0.message.contains("continuation") })
        #expect(try String(contentsOf: current, encoding: .utf8) == content)
        let limited = try await reader.read(interval: DateInterval(start: .distantPast, end: .distantFuture), categories: [], warningsOnly: false, maxBytes: 80)
        #expect(limited.reduce(0) { $0 + $1.message.utf8.count } <= 80)
        #expect(limited.first?.message.contains("newest") == true)
    }
}

struct EmptyAILogs: AILogReader {
    func read(interval: DateInterval, categories: Set<String>, warningsOnly: Bool, maxBytes: Int) async throws -> [AILogEntry] { [] }
}

struct FailingAISource: AITrioDataReading {
    func settings() async throws -> AISettingsSnapshot { throw AIError.invalidResponse }
    func glucose(in interval: DateInterval, limit: Int) async throws -> [AIGlucose] { throw AIError.invalidResponse }
    func pumpHistory(in interval: DateInterval, limit: Int) async throws -> [AIPumpEvent] { throw AIError.invalidResponse }
    func carbs(in interval: DateInterval, limit: Int) async throws -> [AICarbEntry] { throw AIError.invalidResponse }
    func determinations(in interval: DateInterval, limit: Int) async throws -> [AIDetermination] { throw AIError.invalidResponse }
}

struct ContextSourceFixture: AITrioDataReading {
    let now: Date
    var glucoseEntries: [AIGlucose]?
    var pumpEntries: [AIPumpEvent] = []
    var carbEntries: [AICarbEntry] = []
    func settings() async throws -> AISettingsSnapshot { .init(settings: [], preferences: [], pumpSettings: [], schedules: []) }
    func glucose(in interval: DateInterval, limit: Int) async throws -> [AIGlucose] {
        if let glucoseEntries { return glucoseEntries }
        return [(-7200.0, 80), (-3600, 100), (-60, 130), (0, 140), (60, 200)].map {
            AIGlucose(date: now.addingTimeInterval($0.0), glucoseMgDL: $0.1, smoothedGlucoseMgDL: nil, direction: nil, isManual: false)
        }
    }
    func pumpHistory(in interval: DateInterval, limit: Int) async throws -> [AIPumpEvent] { pumpEntries }
    func carbs(in interval: DateInterval, limit: Int) async throws -> [AICarbEntry] { carbEntries }
    func determinations(in interval: DateInterval, limit: Int) async throws -> [AIDetermination] { [] }
}

extension FailingAISource {
    func pumpBoundaryEvents(before date: Date) async throws -> [AIPumpEvent] { throw AIError.invalidResponse }
    func totalDailyDose(in interval: DateInterval) async throws -> AITotalDailyDose? { throw AIError.invalidResponse }
    func adjustments(in interval: DateInterval, limit: Int) async throws -> [AIAdjustment] { throw AIError.invalidResponse }
}

extension ContextSourceFixture {
    func pumpBoundaryEvents(before date: Date) async throws -> [AIPumpEvent] { [] }
    func totalDailyDose(in interval: DateInterval) async throws -> AITotalDailyDose? { nil }
    func adjustments(in interval: DateInterval, limit: Int) async throws -> [AIAdjustment] { [] }
}
