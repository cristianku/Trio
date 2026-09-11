import AppIntents
import Foundation

struct StartSportModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Sport in Trio"
    static var description =
        IntentDescription(
            "Activate the override linked to an activity. Configure an Apple Watch Workout automation in Shortcuts first."
        )
    static var openAppWhenRun = false

    @Parameter(title: "Sport Link") var link: SportRuleEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start sport using \(\.$link)")
    }

    @MainActor func perform() async throws -> some ProvidesDialog {
        // Never fall back to a different rule or prompt for a treatment during automation.
        guard let link else { throw SportModeError.ruleUnavailable }
        guard let coordinator = TrioApp.resolver.resolve(SportModeCoordinator.self) else { throw SportModeError.storageFailure }
        do {
            switch try await coordinator.start(ruleID: link.id) {
            case let .activated(until):
                return .result(
                    dialog: IntentDialog(
                        stringLiteral: String(
                            localized: "Sport override activated until \(until.formatted(date: .omitted, time: .shortened))."
                        )
                    )
                )
            case let .alreadyActive(until):
                return .result(
                    dialog: IntentDialog(stringLiteral: String(
                        localized: "Sport is already active until \(until.formatted(date: .omitted, time: .shortened)). Its duration has not changed."
                    ))
                )
            case .previouslyHandled:
                return .result(
                    dialog: IntentDialog(
                        stringLiteral: String(localized: "Sport was already handled. A canceled override will not be restarted.")
                    )
                )
            }
        } catch let error as SportModeError {
            throw error
        } catch {
            warning(.service, "Sport activation failed", error: error)
            throw SportModeError.storageFailure
        }
    }
}
