import CoreData
import Foundation

struct SportPresetChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let durationMinutes: Double
}

enum SportActivationResult: Equatable {
    case activated(until: Date)
    case alreadyActive(until: Date)
    case previouslyHandled
}

/// No UI, pump commands, remote uploads, or waits for notifications in the transaction.
final class SportModeCoordinator {
    private let settings: () -> TrioSettings
    private let makeContext: () -> NSManagedObjectContext
    private let now: () -> Date

    init(
        settings: @escaping () -> TrioSettings,
        makeContext: @escaping () -> NSManagedObjectContext,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.makeContext = makeContext
        self.now = now
    }

    static func resolveRule(id: UUID, settings: TrioSettings) throws -> SportOverrideRule {
        guard settings.automaticSportEnabled else { throw SportModeError.disabled }
        guard let rule = settings.sportOverrideRules.first(where: { $0.id == id }) else { throw SportModeError.ruleUnavailable }
        guard settings.sportOverrideRules.filter({ $0.id == id }).count == 1,
              settings.sportOverrideRules.filter({ $0.activity == rule.activity }).count == 1
        else {
            throw SportModeError.duplicateActivity
        }
        return rule
    }

    func presets() async throws -> [SportPresetChoice] {
        let context = makeContext()
        return try await context.perform {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "isPreset == YES")
            request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
            return try context.fetch(request).compactMap { preset in
                guard let id = preset.id, !id.isEmpty, let name = preset.name,
                      Self.validDuration(preset) != nil else { return nil }
                return SportPresetChoice(id: id, name: name, durationMinutes: preset.duration!.doubleValue)
            }
        }
    }

    func start(ruleID: UUID) async throws -> SportActivationResult {
        let context = makeContext()
        context.name = "SportModeActivation"
        do {
            let result = try await context.perform {
                try SportOverrideTransaction.withLock {
                    // Resolve current settings here, not when Shortcuts cached its entity.
                    let rule = try Self.resolveRule(id: ruleID, settings: self.settings())
                    let date = self.now()
                    let presetRequest = OverrideStored.fetchRequest()
                    presetRequest.predicate = NSPredicate(format: "id == %@ AND isPreset == YES", rule.overridePresetID)
                    let matches = try context.fetch(presetRequest)
                    guard matches.count == 1, let preset = matches.first,
                          let minutes = Self.validDuration(preset) else { throw SportModeError.invalidPreset }

                    // No 24-hour lookback: an indefinite manual override may be older.
                    let overrides = try context.fetch(OverrideStored.fetchRequest())
                    let targets = try context.fetch(TempTargetStored.fetchRequest())
                    if overrides.contains(where: { $0.sportRuleID == nil && SportOverrideTransaction.isActive($0, at: date) }) {
                        throw SportModeError.overrideConflict
                    }
                    if targets.contains(where: { SportOverrideTransaction.isActive($0, at: date) }) {
                        throw SportModeError.tempTargetConflict
                    }
                    if let current = overrides
                        .first(where: { $0.sportRuleID != nil && SportOverrideTransaction.isActive($0, at: date) })
                    {
                        guard current.sportRuleID == rule.id else { throw SportModeError.overrideConflict }
                        return SportActivationResult
                            .alreadyActive(until: current.date!.addingTimeInterval(current.duration!.doubleValue * 60))
                    }
                    // Cancellation or manual replacement must not re-enable sport on duplicate delivery.
                    if overrides.contains(where: { record in
                        guard record.sportRuleID != nil, let start = record.date,
                              let duration = Self.validDuration(record) else { return false }
                        return start <= date && date < start.addingTimeInterval(duration * 60)
                    }) { return SportActivationResult.previouslyHandled }

                    // Close already-ended rows so neither sport expiry nor manual
                    // cancellation can expose a stale enabled override underneath it.
                    for expired in overrides where expired.enabled {
                        if let start = expired.date, let duration = Self.validDuration(expired),
                           start.addingTimeInterval(duration * 60) <= date
                        {
                            SportOverrideTransaction.finish(expired, at: start.addingTimeInterval(duration * 60), in: context)
                        }
                    }
                    let activation = OverrideStored(context: context)
                    // Copy every current therapy attribute, but no history relationship or template identity.
                    for key in preset.entity.attributesByName.keys {
                        activation.setValue(preset.value(forKey: key), forKey: key)
                    }
                    activation.id = UUID().uuidString
                    activation.sportRuleID = rule.id
                    activation.name = String(localized: "Sport: \(preset.name ?? rule.activity.displayName)")
                    activation.date = date
                    activation.enabled = true
                    activation.isPreset = false
                    activation.isUploadedToNS = false
                    activation.orderPosition = 0
                    try context.save()
                    return SportActivationResult.activated(until: date.addingTimeInterval(minutes * 60))
                }
            }
            // Existing history/FRC consumers observe the committed transaction. No dependency on Nightscout.
            if case .activated = result {
                await MainActor.run {
                    Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
                }
            }
            return result
        } catch {
            await context.perform { context.rollback() }
            throw error
        }
    }

    static func validDuration(_ record: OverrideStored) -> Double? {
        guard !record.indefinite, let duration = record.duration?.doubleValue,
              duration.isFinite, duration > 0, (duration * 60).isFinite else { return nil }
        return duration
    }
}
