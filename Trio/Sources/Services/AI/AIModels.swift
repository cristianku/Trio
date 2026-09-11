import Foundation

enum AIHistoryWindow: Int, Codable, CaseIterable, Identifiable {
    case one = 1
    case three = 3
    case six = 6
    case twelve = 12
    case twentyFour = 24
    case twoDays = 48
    case threeDays = 72
    case sevenDays = 168
    var id: Int { rawValue }
    var title: String { rawValue < 48 ? String(localized: "\(rawValue) hours") : String(localized: "\(rawValue / 24) days") }
}

enum AIContextMode: String, Codable { case automatic, manual }

enum AIContextCategory: String, Codable, CaseIterable, Identifiable {
    case settings
    case glucose
    case pumpHistory
    case carbs
    case determinations
    case adjustments
    case logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .settings: return String(localized: "Settings and Preferences")
        case .glucose: return String(localized: "Glucose")
        case .pumpHistory: return String(localized: "Insulin / Pump History")
        case .carbs: return String(localized: "Carbohydrates")
        case .determinations: return String(localized: "Algorithm Determinations (IOB / COB)")
        case .adjustments: return String(localized: "Overrides and Temporary Targets")
        case .logs: return String(localized: "Application Logs")
        }
    }
}

struct AIConfiguration: Codable, Equatable {
    var enabled = false
    var consentVersion = 0
    var model = AIPrompt.defaultModel
    var historyHours: AIHistoryWindow = .six
    var categories: Set<AIContextCategory> = []
    var warningsOnly = true
    var remoteContinuity = false
    // Optional for archives created before automatic selection existed.
    var contextMode: AIContextMode? = .automatic
    var automaticallySelectContext: Bool {
        get { contextMode != .manual }
        set { contextMode = newValue ? .automatic : .manual }
    }

    mutating func selectTherapyContext() {
        categories.formUnion([.settings, .glucose, .pumpHistory, .carbs, .determinations, .adjustments])
    }

    var hasConsent: Bool { consentVersion == AIPrompt.consentVersion }
}

struct AIMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    let content: String
    var createdAt = Date()
}

struct AIConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var lastResponseID: String?
    var messages: [AIMessage] = []

    var displayTitle: String {
        messages.isEmpty && title == "New Conversation" ? String(localized: "New Conversation") : title
    }
}

struct AIArchive: Codable {
    var version = 1
    var configuration = AIConfiguration()
    var conversations: [AIConversation] = []
    var lastRequestBytes: Int?
}

struct AIContextLimits {
    var glucose = 300
    var pumpHistory = 300
    var carbs = 100
    var determinations = 100
    var adjustments = 50
    var logBytes = 16000
    static let requestBytes = 240_000
    static let messageCharacters = 6000
    static let conversationCharacters = 24000
}

struct AISetting: Codable {
    let name: String
    let value: String
}

struct AISettingsSnapshot: Codable {
    let settings: [AISetting]
    let preferences: [AISetting]
    let pumpSettings: [AISetting]
    let schedules: [AIScheduleEntry]
}

struct AIScheduleEntry: Codable {
    let kind: String
    let start: String
    let value: Decimal
    var upperValue: Decimal?
    let unit: String
}

protocol AIDatedEntry { var date: Date { get } }

struct AIGlucose: Codable, AIDatedEntry {
    let date: Date
    let glucoseMgDL: Int
    let smoothedGlucoseMgDL: Decimal?
    let direction: String?
    let isManual: Bool
}

struct AIPumpEvent: Codable, AIDatedEntry {
    let date: Date
    let type: String
    let insulinUnits: Decimal?
    let rateUnitsPerHour: Decimal?
    let durationMinutes: Int?
    let isSMB: Bool?
    let isExternal: Bool?
}

struct AITotalDailyDose: Codable {
    let date: Date
    let totalUnits: Decimal?
    let bolusUnits: Decimal?
    let tempBasalUnits: Decimal?
    let scheduledBasalUnits: Decimal?
    let weightedAverageUnits: Decimal?
}

struct AIAdjustment: Codable {
    let kind: String
    let source: String
    let startDate: Date
    let endDate: Date?
    let plannedEndDate: Date?
    let targetMgDL: Decimal?
    let parameters: [AISetting]

    func overlaps(_ interval: DateInterval) -> Bool {
        startDate <= interval.end && (endDate ?? plannedEndDate ?? .distantFuture) > interval.start
    }
}

struct AICarbEntry: Codable, AIDatedEntry {
    let date: Date
    let grams: Double
    let fatGrams: Double
    let proteinGrams: Double
    let isFPU: Bool
}

struct AIDetermination: Codable, AIDatedEntry {
    let date: Date
    let enactedAt: Date?
    let enacted: Bool
    let reason: String?
    let glucoseMgDL: Decimal?
    let eventualGlucoseMgDL: Decimal?
    let targetMgDL: Decimal?
    let iobUnits: Decimal?
    let cobGrams: Int
    let smbUnits: Decimal?
    let basalRateUnitsPerHour: Decimal?
    let durationMinutes: Decimal?
    let insulinRequirementUnits: Decimal?
    let sensitivityMgDLPerUnit: Decimal?
    let sensitivityRatio: Decimal?
    let carbRatioGramsPerUnit: Decimal?
    let scheduledBasalUnitsPerHour: Decimal?
}

struct AILogEntry: Codable, AIDatedEntry {
    let date: Date
    let category: String
    let message: String
}

struct TrioAIContext: Codable {
    let generatedAt: Date
    let intervalStart: Date
    let timeZone: String
    let appVersion: String?
    let includedCategories: [String]
    var configuration: AISettingsSnapshot?
    var glucose: [AIGlucose] = []
    var pumpHistory: [AIPumpEvent] = []
    var pumpStateBeforeInterval: [AIPumpEvent] = []
    var latestStoredTDD: AITotalDailyDose?
    var adjustments: [AIAdjustment] = []
    var carbs: [AICarbEntry] = []
    var determinations: [AIDetermination] = []
    var logs: [AILogEntry] = []
    var notes: [String] = []
    var intervalEnd: Date?
    var hourlySummaries: [AIHistorySummary]?
}

/// Observations in one hour, never a calculation of delivered basal insulin or therapy advice.
struct AIHistorySummary: Codable {
    let start: Date
    let end: Date
    var glucose: Glucose?
    var pump: Pump?
    var carbs: Carbs?
    var determinations: Determinations?

    struct Glucose: Codable {
        let count: Int
        let first: Date
        let last: Date
        let minimumMgDL: Int
        let maximumMgDL: Int
        let meanMgDL: Double
    }

    struct Pump: Codable {
        let eventCounts: [String: Int]
        let recordedPumpBolusUnits: Decimal
        let recordedExternalInsulinUnits: Decimal
        let unclassifiedInsulinUnits: Decimal
    }

    struct Carbs: Codable {
        let count: Int
        let recordedMealGrams: Double
        let recordedFPUGrams: Double
    }

    struct Determinations: Codable {
        let count: Int
        let enactedCount: Int
    }
}

enum AIError: LocalizedError {
    case disabled
    case consentRequired
    case missingCredential
    case invalidModel
    case emptyMessage
    case busy
    case missingConversation
    case persistence
    case invalidResponse
    case responseTooLarge
    case requestTooLarge
    case network
    case cancelled
    case invalidContextPlan
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disabled: return String(localized: "Enable AI Assistant in AI Settings before sending.")
        case .consentRequired: return String(localized: "Review and accept the data sharing information before sending.")
        case .missingCredential: return String(localized: "Add or replace your OpenAI API key in AI Settings.")
        case .invalidModel: return String(localized: "Enter a valid OpenAI model ID in AI Settings.")
        case .emptyMessage: return String(localized: "Enter a question (up to 6,000 characters).")
        case .busy: return String(localized: "A request is already running. Cancel it or wait for it to finish.")
        case .missingConversation: return String(localized: "This conversation is no longer available.")
        case .persistence: return String(localized: "AI history could not be read or saved. Existing data has not been reset.")
        case .invalidResponse: return String(localized: "OpenAI returned no complete text response. Try again or check the model.")
        case .responseTooLarge: return String(localized: "The response exceeded the download limit.")
        case .requestTooLarge: return String(localized: "The request is too large. Try asking about a shorter period.")
        case .network: return String(localized: "Could not reach OpenAI. Check your connection and try again.")
        case .cancelled: return String(localized: "Request cancelled.")
        case .invalidContextPlan: return String(localized: "Could not select the requested time period. Please try asking again.")
        case let .api(status, message): return "OpenAI (\(status)): \(message)"
        }
    }
}
