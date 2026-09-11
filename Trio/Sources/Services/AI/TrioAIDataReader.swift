import CoreData
import Foundation

/// The only Core Data bridge. Fetch/map happens on a private context queue. Never saves or returns managed objects.
final class TrioAIDataReader: AITrioDataReading {
    private let makeContext: () -> NSManagedObjectContext
    private let readSettings: () -> AISettingsSnapshot

    init(makeContext: @escaping () -> NSManagedObjectContext, readSettings: @escaping () -> AISettingsSnapshot) {
        self.makeContext = makeContext
        self.readSettings = readSettings
    }

    func settings() async throws -> AISettingsSnapshot { readSettings() }

    private func read<T: NSManagedObject, Value>(
        _ type: T.Type, interval: DateInterval, key: String, limit: Int,
        relationships: [String] = [], predicate: NSPredicate? = nil, map: @escaping (T) -> Value?
    ) async throws -> [Value] {
        let context = makeContext()
        return try await context.perform {
            let request = NSFetchRequest<T>(entityName: String(describing: type))
            request.predicate = predicate ?? NSPredicate(
                format: "%K >= %@ AND %K <= %@",
                key,
                interval.start as NSDate,
                key,
                interval.end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
            request.fetchLimit = max(1, limit)
            request.fetchBatchSize = min(50, max(1, limit))
            request.relationshipKeyPathsForPrefetching = relationships
            request.includesPendingChanges = false
            return try context.fetch(request).compactMap(map)
        }
    }

    func glucose(in interval: DateInterval, limit: Int) async throws -> [AIGlucose] {
        try await read(GlucoseStored.self, interval: interval, key: "date", limit: limit) {
            guard let date = $0.date else { return nil }
            return AIGlucose(
                date: date,
                glucoseMgDL: Int($0.glucose),
                smoothedGlucoseMgDL: $0.smoothedGlucose?.decimalValue,
                direction: $0.direction,
                isManual: $0.isManual
            )
        }
    }

    func pumpHistory(in interval: DateInterval, limit: Int) async throws -> [AIPumpEvent] {
        try await read(
            PumpEventStored.self,
            interval: interval,
            key: "timestamp",
            limit: limit,
            relationships: ["bolus", "tempBasal"]
        ) {
            Self.pumpEvent($0)
        }
    }

    func carbs(in interval: DateInterval, limit: Int) async throws -> [AICarbEntry] {
        try await read(CarbEntryStored.self, interval: interval, key: "date", limit: limit) {
            guard let date = $0.date else { return nil }
            return AICarbEntry(date: date, grams: $0.carbs, fatGrams: $0.fat, proteinGrams: $0.protein, isFPU: $0.isFPU)
        }
    }

    func determinations(in interval: DateInterval, limit: Int) async throws -> [AIDetermination] {
        try await read(OrefDetermination.self, interval: interval, key: "deliverAt", limit: limit) {
            guard let date = $0.deliverAt else { return nil }
            return AIDetermination(
                date: date,
                enactedAt: $0.timestampEnacted,
                enacted: $0.enacted,
                reason: $0.reason,
                glucoseMgDL: $0.glucose?.decimalValue,
                eventualGlucoseMgDL: $0.eventualBG?.decimalValue,
                targetMgDL: $0.currentTarget?.decimalValue,
                iobUnits: $0.iob?.decimalValue,
                cobGrams: Int($0.cob),
                smbUnits: $0.smbToDeliver?.decimalValue,
                basalRateUnitsPerHour: $0.rate?.decimalValue,
                durationMinutes: $0.duration?.decimalValue,
                insulinRequirementUnits: $0.insulinReq?.decimalValue,
                sensitivityMgDLPerUnit: $0.insulinSensitivity?.decimalValue,
                sensitivityRatio: $0.sensitivityRatio?.decimalValue,
                carbRatioGramsPerUnit: $0.carbRatio?.decimalValue,
                scheduledBasalUnitsPerHour: $0.scheduledBasal?.decimalValue
            )
        }
    }
}

private extension TrioAIDataReader {
    static func pumpEvent(_ event: PumpEventStored) -> AIPumpEvent? {
        guard let date = event.timestamp else { return nil }
        return AIPumpEvent(
            date: date, type: event.type ?? "unknown", insulinUnits: event.bolus?.amount?.decimalValue,
            rateUnitsPerHour: event.tempBasal?.rate?.decimalValue,
            durationMinutes: event.tempBasal.map { Int($0.duration) },
            isSMB: event.bolus?.isSMB, isExternal: event.bolus?.isExternal
        )
    }

    static func overrideParameters(_ value: OverrideStored?) -> [AISetting] {
        guard let value else { return [] }
        return [
            .init(name: "percentage", value: String(value.percentage)),
            .init(name: "indefinite", value: String(value.indefinite)),
            .init(name: "durationMinutes", value: value.duration?.stringValue ?? "unknown"),
            .init(name: "isf", value: String(value.isf)),
            .init(name: "cr", value: String(value.cr)),
            .init(name: "isfAndCr", value: String(value.isfAndCr)),
            .init(name: "advancedSettings", value: String(value.advancedSettings)),
            .init(name: "smbIsOff", value: String(value.smbIsOff)),
            .init(name: "smbIsScheduledOff", value: String(value.smbIsScheduledOff)),
            .init(name: "smbOffStartHour", value: value.start?.stringValue ?? "unknown"),
            .init(name: "smbOffEndHour", value: value.end?.stringValue ?? "unknown"),
            .init(name: "maxSMBBasalMinutes", value: value.smbMinutes?.stringValue ?? "unknown"),
            .init(name: "maxUAMSMBBasalMinutes", value: value.uamMinutes?.stringValue ?? "unknown")
        ]
    }
}

extension TrioAIDataReader {
    func pumpBoundaryEvents(before date: Date) async throws -> [AIPumpEvent] {
        let interval = DateInterval(start: .distantPast, end: date)
        let basal = try await read(
            PumpEventStored.self, interval: interval, key: "timestamp", limit: 1, relationships: ["tempBasal"],
            predicate: NSPredicate(format: "timestamp < %@ AND type == %@", date as NSDate, "TempBasal"),
            map: Self.pumpEvent
        ).filter { event in
            guard let minutes = event.durationMinutes else { return false }
            return event.date.addingTimeInterval(Double(minutes) * 60) > date
        }
        let operatingState = try await read(
            PumpEventStored.self, interval: interval, key: "timestamp", limit: 1,
            predicate: NSPredicate(format: "timestamp < %@ AND type IN %@", date as NSDate, ["PumpSuspend", "PumpResume"]),
            map: Self.pumpEvent
        )
        return (basal + operatingState).sorted { $0.date > $1.date }
    }

    func totalDailyDose(in interval: DateInterval) async throws -> AITotalDailyDose? {
        let values: [AITotalDailyDose] = try await read(TDDStored.self, interval: interval, key: "date", limit: 1) {
            guard let date = $0.date else { return nil }
            return AITotalDailyDose(
                date: date, totalUnits: $0.total?.decimalValue, bolusUnits: $0.bolus?.decimalValue,
                tempBasalUnits: $0.tempBasal?.decimalValue, scheduledBasalUnits: $0.scheduledBasal?.decimalValue,
                weightedAverageUnits: $0.weightedAverage?.decimalValue
            )
        }
        return values.first
    }

    func adjustments(in interval: DateInterval, limit: Int) async throws -> [AIAdjustment] {
        let overlap = NSPredicate(
            format: "startDate <= %@ AND (endDate == nil OR endDate > %@)",
            interval.end as NSDate, interval.start as NSDate
        )
        let overrideRuns: [AIAdjustment] = try await read(
            OverrideRunStored.self, interval: interval, key: "startDate", limit: limit,
            relationships: ["override"], predicate: overlap
        ) {
            guard let start = $0.startDate else { return nil }
            return AIAdjustment(
                kind: "override",
                source: "recordedRun",
                startDate: start,
                endDate: $0.endDate,
                plannedEndDate: nil,
                targetMgDL: $0.target?.decimalValue,
                parameters: Self.overrideParameters($0.override)
            )
        }
        let targetRuns: [AIAdjustment] = try await read(
            TempTargetRunStored.self, interval: interval, key: "startDate", limit: limit,
            relationships: ["tempTarget"], predicate: overlap
        ) {
            guard let start = $0.startDate else { return nil }
            return AIAdjustment(
                kind: "tempTarget",
                source: "recordedRun",
                startDate: start,
                endDate: $0.endDate,
                plannedEndDate: nil,
                targetMgDL: $0.target?.decimalValue,
                parameters: [.init(
                    name: "halfBasalTargetMgDL",
                    value: $0.tempTarget?.halfBasalTarget?.stringValue ?? "uses preference"
                )]
            )
        }
        let enabled = NSPredicate(format: "enabled == YES AND date <= %@", interval.end as NSDate)
        let overrides: [AIAdjustment] = try await read(
            OverrideStored.self, interval: interval, key: "date", limit: limit, predicate: enabled
        ) {
            guard let start = $0.date else { return nil }
            let plannedEnd = $0.indefinite ? nil : $0.duration.map { start.addingTimeInterval($0.doubleValue * 60) }
            return AIAdjustment(
                kind: "override",
                source: "currentlyEnabledConfiguration",
                startDate: start,
                endDate: nil,
                plannedEndDate: plannedEnd,
                targetMgDL: $0.target?.decimalValue,
                parameters: Self.overrideParameters($0)
            )
        }
        let targets: [AIAdjustment] = try await read(
            TempTargetStored.self, interval: interval, key: "date", limit: limit, predicate: enabled
        ) {
            guard let start = $0.date else { return nil }
            return AIAdjustment(
                kind: "tempTarget",
                source: "currentlyEnabledConfiguration",
                startDate: start,
                endDate: nil,
                plannedEndDate: $0.duration.map { start.addingTimeInterval($0.doubleValue * 60) },
                targetMgDL: $0.target?.decimalValue,
                parameters: [.init(
                    name: "halfBasalTargetMgDL",
                    value: $0.halfBasalTarget?.stringValue ?? "uses preference"
                )]
            )
        }
        return Array(
            (overrideRuns + targetRuns + overrides + targets)
                .filter { $0.overlaps(interval) }.sorted { $0.startDate > $1.startDate }.prefix(max(0, limit))
        )
    }
}
