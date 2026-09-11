import Foundation

enum SportActivityKind: String, Codable, CaseIterable, Identifiable {
    case running
    case cycling
    case walking
    case swimming
    case hiking
    case strengthTraining
    case yoga
    case other

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .running: return String(localized: "Running")
        case .cycling: return String(localized: "Cycling")
        case .walking: return String(localized: "Walking")
        case .swimming: return String(localized: "Swimming")
        case .hiking: return String(localized: "Hiking")
        case .strengthTraining: return String(localized: "Strength Training")
        case .yoga: return String(localized: "Yoga")
        case .other: return String(localized: "Other Workout")
        }
    }
}

struct SportOverrideRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var activity: SportActivityKind
    var overridePresetID: String

    /// A preset edit preserves the shortcut; an activity edit invalidates its old trigger.
    static func saving(id: UUID?, activity: SportActivityKind, presetID: String, in rules: [Self]) throws -> [Self] {
        guard !presetID.isEmpty else { throw SportModeError.invalidPreset }
        guard !rules.contains(where: { $0.id != id && $0.activity == activity }) else {
            throw SportModeError.duplicateActivity
        }
        var result = rules
        if let id {
            guard let index = result.firstIndex(where: { $0.id == id }) else { throw SportModeError.ruleUnavailable }
            let replacementID = result[index].activity == activity ? id : UUID()
            result[index] = Self(id: replacementID, activity: activity, overridePresetID: presetID)
        } else {
            result.append(Self(activity: activity, overridePresetID: presetID))
        }
        return result
    }
}

enum SportModeError: Error, LocalizedError, Equatable {
    case disabled
    case ruleUnavailable
    case duplicateActivity
    case invalidPreset
    case overrideConflict
    case tempTargetConflict
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .disabled: return String(localized: "Automatic Sport is off.")
        case .ruleUnavailable: return String(localized: "Sport link unavailable. Update the automation in Shortcuts.")
        case .duplicateActivity: return String(localized: "This activity already has an override link.")
        case .invalidPreset: return String(localized: "Choose an existing override with a finite, positive duration.")
        case .overrideConflict: return String(localized: "Sport skipped: another override is active.")
        case .tempTargetConflict: return String(localized: "Sport skipped: a temporary target is active.")
        case .storageFailure: return String(localized: "Could not save the sport override. Check Trio before trying again.")
        }
    }
}
