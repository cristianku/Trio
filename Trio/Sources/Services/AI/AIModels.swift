import Foundation

enum AIHistoryWindow: Int, Codable, CaseIterable, Identifiable {
    case one = 1, three = 3, six = 6, twelve = 12, twentyFour = 24
    var id: Int { rawValue }
}

enum AIContextCategory: String, Codable, CaseIterable, Identifiable {
    case settings, glucose, pumpHistory, carbs, determinations, adjustments, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .settings: return "Settings and Preferences"
        case .glucose: return "Glucose"
        case .pumpHistory: return "Insulin / Pump History"
        case .carbs: return "Carbohydrates"
        case .determinations: return "Algorithm Determinations (IOB / COB)"
        case .adjustments: return "Overrides and Temporary Targets"
        case .logs: return "Application Logs"
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
    static let requestBytes = 240000
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
}

enum AIError: LocalizedError {
    case disabled, consentRequired, missingCredential, invalidModel, emptyMessage, busy, missingConversation
    case persistence, invalidResponse, responseTooLarge, requestTooLarge, network, cancelled
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "Enable AI Assistant in AI Settings before sending."
        case .consentRequired: return "Review and accept the data sharing information before sending."
        case .missingCredential: return "Add or replace your OpenAI API key in AI Settings."
        case .invalidModel: return "Enter a valid OpenAI model ID in AI Settings."
        case .emptyMessage: return "Enter a question (up to 6,000 characters)."
        case .busy: return "A request is already running. Cancel it or wait for it to finish."
        case .missingConversation: return "This conversation is no longer available."
        case .persistence: return "AI history could not be read or saved. Existing data has not been reset."
        case .invalidResponse: return "OpenAI returned no complete text response. Try again or check the model."
        case .responseTooLarge: return "The response exceeded the download limit."
        case .requestTooLarge: return "The request is too large. Select fewer data categories or a shorter window."
        case .network: return "Could not reach OpenAI. Check your connection and try again."
        case .cancelled: return "Request cancelled."
        case let .api(status, message): return "OpenAI (\(status)): \(message)"
        }
    }
}
