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
    func build(configuration: AIConfiguration, interval: DateInterval) async throws -> TrioAIContext
}

extension AIContextBuilder {
    func build(configuration: AIConfiguration, interval: DateInterval) async throws -> TrioAIContext {
        throw AIError.invalidContextPlan
    }
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
        return try await build(configuration: configuration, interval: interval)
    }

    func build(configuration: AIConfiguration, interval: DateInterval) async throws -> TrioAIContext {
        let date = now()
        guard interval.duration > 0, interval.duration <= 168 * 3600,
              interval.end <= date.addingTimeInterval(1), interval.start >= date.addingTimeInterval(-168 * 3600 - 120)
        else { throw AIError.invalidContextPlan }
        var context = TrioAIContext(generatedAt: date, intervalStart: interval.start, timeZone: TimeZone.current.identifier,
                                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                    includedCategories: configuration.categories.map(\.rawValue).sorted())
        context.notes = ["Settings are current, not historical. Glucose uses mg/dL. Insulin uses U and U/hour; carbs use grams.",
                         "Selected history window: \(interval.duration / 3600) hours, from intervalStart to intervalEnd. Selection is rebuilt for each message; it may be a past interval or a rolling recent window. This is a sharing cutoff, not the oldest record stored in Trio. Actual category coverage may be shorter or truncated. Older records may exist locally without being included here. Maximum permitted lookback is 7 days.",
                         "IOB/COB are available only in timestamped determinations. No live IOB/COB or TDD was calculated.",
                         "Missing rows do not prove no event occurred. Deleted records and data not retained locally are unavailable."]
        context.intervalEnd = interval.end
        let summarize = interval.duration > 24 * 3600
        if summarize {
            context.hourlySummaries = try await historySummaries(configuration: configuration, interval: interval, notes: &context.notes)
            context.notes.append("hourlySummaries describe stored observations, not complete coverage or measured insulin delivery. Missing hours are unavailable, not zero events. Glucose means are sample means, not time-weighted averages or time in range. Pump amounts sum recorded bolus amounts only; never add basal rate times duration. FPU carbs are separate from recorded meals. Determination counts are recommendations, not delivered doses. Ask for a narrower period for individual records and reasons.")
        }
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
                if summarize { continue }
                context.glucose = bounded(try await source.glucose(in: interval, limit: limits.glucose + 1), limit: limits.glucose, category: category.rawValue)
            case .pumpHistory:
                if !summarize {
                    context.pumpHistory = bounded(try await source.pumpHistory(in: interval, limit: limits.pumpHistory + 1), limit: limits.pumpHistory, category: category.rawValue)
                }
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
                if summarize { continue }
                context.carbs = bounded(try await source.carbs(in: interval, limit: limits.carbs + 1), limit: limits.carbs, category: category.rawValue)
            case .determinations:
                if summarize { continue }
                context.determinations = bounded(try await source.determinations(in: interval, limit: limits.determinations + 1), limit: limits.determinations, category: category.rawValue)
            case .logs:
                context.logs = try await logs.read(interval: interval, categories: [], warningsOnly: configuration.warningsOnly, maxBytes: limits.logBytes)
                context.notes.append("Logs are bounded to newest matching timestamped lines (\(limits.logBytes) bytes). Continuation lines and older file tails may be omitted.")
            }
        }
        return context
    }

    private func historySummaries(configuration: AIConfiguration, interval: DateInterval, notes: inout [String]) async throws
        -> [AIHistorySummary]
    {
        var summaries: [Int: AIHistorySummary] = [:]
        func hourKey(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 3600)) }
        func bucket(_ key: Int) -> AIHistorySummary {
            summaries[key] ?? AIHistorySummary(start: max(interval.start, Date(timeIntervalSince1970: Double(key) * 3600)),
                                               end: min(interval.end, Date(timeIntervalSince1970: Double(key + 1) * 3600)))
        }
        // Bound local memory per fetch as well as the outgoing summary. No raw week-long arrays are transmitted.
        var start = interval.start
        while start < interval.end {
            try Task.checkCancellation()
            let end = min(start.addingTimeInterval(24 * 3600), interval.end)
            let day = DateInterval(start: start, end: end)
            func selected<T: AIDatedEntry>(_ rows: [T], cap: Int, category: String) -> [T] {
                if rows.count > cap {
                    notes.append("\(category) summary fetch truncated for interval beginning \(start.ISO8601Format()); counts and sums are partial.")
                }
                return Array(rows.prefix(cap)).filter { $0.date >= start && ($0.date < end || (end == interval.end && $0.date == end)) }
            }
            if configuration.categories.contains(.glucose) {
                let rows = selected(try await source.glucose(in: day, limit: 2001), cap: 2000, category: "glucose")
                for (key, values) in Dictionary(grouping: rows, by: { hourKey($0.date) }) {
                    var value = bucket(key)
                    let old = value.glucose
                    let count = values.count + (old?.count ?? 0)
                    let total = values.reduce(0.0) { $0 + Double($1.glucoseMgDL) } + (old?.meanMgDL ?? 0) * Double(old?.count ?? 0)
                    value.glucose = .init(count: count,
                                          first: min(values.map(\.date).min()!, old?.first ?? .distantFuture),
                                          last: max(values.map(\.date).max()!, old?.last ?? .distantPast),
                                          minimumMgDL: min(values.map(\.glucoseMgDL).min()!, old?.minimumMgDL ?? Int.max),
                                          maximumMgDL: max(values.map(\.glucoseMgDL).max()!, old?.maximumMgDL ?? Int.min),
                                          meanMgDL: total / Double(count))
                    summaries[key] = value
                }
            }
            if configuration.categories.contains(.pumpHistory) {
                let rows = selected(try await source.pumpHistory(in: day, limit: 4001), cap: 4000, category: "pumpHistory")
                for (key, values) in Dictionary(grouping: rows, by: { hourKey($0.date) }) {
                    var value = bucket(key)
                    let old = value.pump
                    var counts = old?.eventCounts ?? [:]
                    var pump = old?.recordedPumpBolusUnits ?? 0
                    var external = old?.recordedExternalInsulinUnits ?? 0
                    var unclassified = old?.unclassifiedInsulinUnits ?? 0
                    for event in values {
                        counts[event.type, default: 0] += 1
                        if let units = event.insulinUnits {
                            switch event.isExternal {
                            case true: external += units
                            case false: pump += units
                            case nil: unclassified += units
                            }
                        }
                    }
                    value.pump = .init(eventCounts: counts, recordedPumpBolusUnits: pump,
                                       recordedExternalInsulinUnits: external, unclassifiedInsulinUnits: unclassified)
                    summaries[key] = value
                }
            }
            if configuration.categories.contains(.carbs) {
                let rows = selected(try await source.carbs(in: day, limit: 501), cap: 500, category: "carbs")
                for (key, values) in Dictionary(grouping: rows, by: { hourKey($0.date) }) {
                    var value = bucket(key)
                    let old = value.carbs
                    let meals = values.filter { !$0.isFPU }.reduce(0.0) { $0 + $1.grams }
                    let fpus = values.filter(\.isFPU).reduce(0.0) { $0 + $1.grams }
                    value.carbs = .init(count: values.count + (old?.count ?? 0),
                                        recordedMealGrams: meals + (old?.recordedMealGrams ?? 0),
                                        recordedFPUGrams: fpus + (old?.recordedFPUGrams ?? 0))
                    summaries[key] = value
                }
            }
            if configuration.categories.contains(.determinations) {
                let rows = selected(try await source.determinations(in: day, limit: 2001), cap: 2000, category: "determinations")
                for (key, values) in Dictionary(grouping: rows, by: { hourKey($0.date) }) {
                    var value = bucket(key)
                    value.determinations = .init(count: values.count + (value.determinations?.count ?? 0),
                                                enactedCount: values.filter(\.enacted).count + (value.determinations?.enactedCount ?? 0))
                    summaries[key] = value
                }
            }
            start = end
        }
        return summaries.keys.sorted().compactMap { summaries[$0] }
    }
}
