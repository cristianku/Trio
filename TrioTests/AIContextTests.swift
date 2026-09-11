import Foundation
import Testing

@testable import Trio

@Suite("AI context and logs") struct AIContextTests {
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
    func settings() async throws -> AISettingsSnapshot { .init(settings: [], preferences: [], pumpSettings: [], schedules: []) }
    func glucose(in interval: DateInterval, limit: Int) async throws -> [AIGlucose] {
        [(-7200.0, 80), (-3600, 100), (-60, 130), (0, 140), (60, 200)].map {
            AIGlucose(date: now.addingTimeInterval($0.0), glucoseMgDL: $0.1, smoothedGlucoseMgDL: nil, direction: nil, isManual: false)
        }
    }
    func pumpHistory(in interval: DateInterval, limit: Int) async throws -> [AIPumpEvent] { [] }
    func carbs(in interval: DateInterval, limit: Int) async throws -> [AICarbEntry] { [] }
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
