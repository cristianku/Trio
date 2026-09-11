import CoreData
import Foundation

/// Shared only by adjustment writers. Always enter ON the managed context's queue;
/// never await, dispatch to another context, or wait for UI/network while holding this lock.
/// Sport holds it across fresh fetch + validation + save. Manual writers hold it across
/// retiring any sport activation + their final save, so whichever saves last respects manual priority.
enum SportOverrideTransaction {
    private static let lock = NSRecursiveLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static let therapyKeys: Set<String> = [
        "enabled", "date", "duration", "indefinite", "target", "percentage", "isf", "cr", "isfAndCr",
        "smbIsOff", "smbIsScheduledOff", "start", "end", "smbMinutes", "uamMinutes", "halfBasalTarget", "advancedSettings"
    ]

    static func finish(_ record: OverrideStored, at date: Date, in context: NSManagedObjectContext) {
        record.enabled = false
        record.isUploadedToNS = false
        guard record.overrideRun == nil, let start = record.date, start <= date else { return }
        let run = OverrideRunStored(context: context)
        run.id = UUID()
        run.name = record.name
        run.startDate = start
        if let minutes = SportModeCoordinator.validDuration(record) {
            run.endDate = min(date, start.addingTimeInterval(minutes * 60))
        } else {
            run.endDate = date
        }
        run.target = record.target ?? 0
        run.override = record
        run.isUploadedToNS = false
    }

    static func isActive(_ record: OverrideStored, at date: Date) -> Bool {
        guard record.enabled, let start = record.date, start <= date else { return false }
        if record.indefinite { return record.sportRuleID == nil }
        guard let duration = record.duration?.doubleValue, duration.isFinite, duration > 0 else { return false }
        return date < start.addingTimeInterval(duration * 60)
    }

    static func isActive(_ record: TempTargetStored, at date: Date) -> Bool {
        guard record.enabled, let start = record.date, start <= date,
              let duration = record.duration?.doubleValue, duration.isFinite, duration > 0 else { return false }
        return date < start.addingTimeInterval(duration * 60)
    }
}

extension NSManagedObjectContext {
    /// Used by override/temporary-target activation writers, including watch and shortcuts.
    /// A future scheduled target or an inactive preset does not end current sport.
    func saveWithSportPrecedence(at date: Date = Date()) throws {
        try SportOverrideTransaction.withLock {
            // Editing the automatic activation is an explicit manual takeover. Keep
            // its original identity/window as a canceled record for history/deduplication.
            for sport in updatedObjects.compactMap({ $0 as? OverrideStored }) where sport.sportRuleID != nil && sport.enabled {
                guard !Set(sport.changedValues().keys).isDisjoint(with: SportOverrideTransaction.therapyKeys) else { continue }
                let attributes = Array(sport.entity.attributesByName.keys)
                let original = sport.committedValues(forKeys: attributes)
                let retired = OverrideStored(context: self)
                for key in attributes {
                    let value = original[key]
                    retired.setValue(value is NSNull ? nil : value, forKey: key)
                }
                SportOverrideTransaction.finish(retired, at: date, in: self)
                sport.sportRuleID = nil
                sport.id = UUID().uuidString
                sport.isUploadedToNS = false
            }
            let manualActivation = insertedObjects.union(updatedObjects).contains { object in
                let changes = Set(object.changedValues().keys)
                guard object.isInserted || !changes.isDisjoint(with: SportOverrideTransaction.therapyKeys) else { return false }
                if let manual = object as? OverrideStored {
                    return manual.sportRuleID == nil && SportOverrideTransaction.isActive(manual, at: date)
                }
                if let target = object as? TempTargetStored {
                    return SportOverrideTransaction.isActive(target, at: date)
                }
                return false
            }
            if manualActivation {
                let request = OverrideStored.fetchRequest()
                request.predicate = NSPredicate(format: "sportRuleID != nil AND enabled == YES")
                request.shouldRefreshRefetchedObjects = true
                for sport in try fetch(request) {
                    SportOverrideTransaction.finish(sport, at: date, in: self)
                }
            }
            try save()
        }
    }
}
