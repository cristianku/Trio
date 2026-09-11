import Foundation

/// This is the entire therapy-facing API available to the AI domain. No mutable objects cross it.
protocol AITrioDataReading {
    func settings() async throws -> AISettingsSnapshot
    func glucose(in interval: DateInterval, limit: Int) async throws -> [AIGlucose]
    func pumpHistory(in interval: DateInterval, limit: Int) async throws -> [AIPumpEvent]
    func pumpBoundaryEvents(before date: Date) async throws -> [AIPumpEvent]
    func totalDailyDose(in interval: DateInterval) async throws -> AITotalDailyDose?
    func adjustments(in interval: DateInterval, limit: Int) async throws -> [AIAdjustment]
    func carbs(in interval: DateInterval, limit: Int) async throws -> [AICarbEntry]
    func determinations(in interval: DateInterval, limit: Int) async throws -> [AIDetermination]
}

protocol AIContextBuilder {
    func build(configuration: AIConfiguration) async throws -> TrioAIContext
}

final class TrioAIContextBuilder: AIContextBuilder {
    private let source: AITrioDataReading
    private let logs: AILogReader
    private let now: () -> Date
    private let limits: AIContextLimits

    init(source: AITrioDataReading, logs: AILogReader, now: @escaping () -> Date = Date.init, limits: AIContextLimits = .init()) {
        self.source = source
        self.logs = logs
        self.now = now
        self.limits = limits
    }

    func build(configuration: AIConfiguration) async throws -> TrioAIContext {
        let date = now()
        let interval = DateInterval(start: date.addingTimeInterval(-Double(configuration.historyHours.rawValue) * 3600), end: date)
        var context = TrioAIContext(generatedAt: date, intervalStart: interval.start, timeZone: TimeZone.current.identifier,
                                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                    includedCategories: configuration.categories.map(\.rawValue).sorted())
        context.notes = ["Settings are current, not historical. Glucose uses mg/dL. Insulin uses U and U/hour; carbs use grams.",
                         "IOB/COB are available only in timestamped determinations. No live IOB/COB or TDD was calculated.",
                         "Missing rows do not prove no event occurred. Deleted records and data not retained locally are unavailable."]
        func bounded<T: AIDatedEntry>(_ values: [T], limit: Int, category: String) -> [T] {
            let relevant = values.filter { $0.date >= interval.start && $0.date <= interval.end }.sorted { $0.date > $1.date }
            if relevant.count > limit { context.notes.append("\(category) truncated to newest \(limit) entries.") }
            return Array(relevant.prefix(max(0, limit)))
        }
        for category in configuration.categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            switch category {
            case .settings: context.configuration = try await source.settings()
            case .glucose:
                context.glucose = bounded(try await source.glucose(in: interval, limit: limits.glucose + 1), limit: limits.glucose, category: category.rawValue)
            case .pumpHistory:
                context.pumpHistory = bounded(try await source.pumpHistory(in: interval, limit: limits.pumpHistory + 1), limit: limits.pumpHistory, category: category.rawValue)
                context.pumpStateBeforeInterval = try await source.pumpBoundaryEvents(before: interval.start)
                context.latestStoredTDD = try await source.totalDailyDose(in: interval)
                context.notes.append("Pump history contains stored bolus amounts (which may be updated after partial delivery), external insulin records, temp basal programs, suspensions and resumptions. Stored events do not retain every pump delivery/finalization flag. Do not infer exact basal delivery from rate times duration. pumpStateBeforeInterval contains at most two preceding state records, not doses in this interval. TDD is an existing daily estimate at its timestamp, not insulin delivered in the selected interval; do not add it to event doses.")
            case .adjustments:
                let values = try await source.adjustments(in: interval, limit: limits.adjustments + 1)
                let relevant = values.filter { $0.overlaps(interval) }.sorted { $0.startDate > $1.startDate }
                context.adjustments = Array(relevant.prefix(limits.adjustments))
                if relevant.count > limits.adjustments { context.notes.append("adjustments truncated to newest \(limits.adjustments) entries.") }
                context.notes.append("Adjustments include recorded runs and currently enabled configurations overlapping the interval, including starts before it. Planned end dates are not observed end times. Parameters come from linked stored configurations and are unavailable if that link no longer exists.")
            case .carbs:
                context.carbs = bounded(try await source.carbs(in: interval, limit: limits.carbs + 1), limit: limits.carbs, category: category.rawValue)
            case .determinations:
                context.determinations = bounded(try await source.determinations(in: interval, limit: limits.determinations + 1), limit: limits.determinations, category: category.rawValue)
            case .logs:
                context.logs = try await logs.read(interval: interval, categories: [], warningsOnly: configuration.warningsOnly, maxBytes: limits.logBytes)
                context.notes.append("Logs are bounded to newest matching timestamped lines (\(limits.logBytes) bytes). Continuation lines and older file tails may be omitted.")
            }
        }
        return context
    }
}
