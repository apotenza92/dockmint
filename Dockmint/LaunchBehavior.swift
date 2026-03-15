import Foundation

struct LaunchBehaviorInput: Equatable {
    let isDebugBuild: Bool
    let onboardingCompleted: Bool
    let showOnStartup: Bool
    let launchArgumentsRequestSettings: Bool
    let launchedFromFinder: Bool
}

enum InitialWindowRequest: Equatable {
    case none
    case onboarding
    case settings(explicit: Bool)
}

struct LaunchBehaviorDecision: Equatable {
    let initialWindowRequest: InitialWindowRequest
    let shouldRequestSettingsFromExistingInstance: Bool

    var shouldShowWindow: Bool {
        initialWindowRequest != .none
    }

    var isExplicitSettingsRequest: Bool {
        if case let .settings(explicit) = initialWindowRequest {
            return explicit
        }
        return false
    }
}

enum LaunchBehavior {
    static func decide(_ input: LaunchBehaviorInput) -> LaunchBehaviorDecision {
        let explicitSettingsRequest = input.launchArgumentsRequestSettings

        let initialWindowRequest: InitialWindowRequest
        if !input.onboardingCompleted {
            initialWindowRequest = .onboarding
        } else if explicitSettingsRequest || input.showOnStartup || input.isDebugBuild {
            initialWindowRequest = .settings(explicit: explicitSettingsRequest)
        } else {
            initialWindowRequest = .none
        }

        let shouldRequestSettingsFromExistingInstance = explicitSettingsRequest
            || (input.launchedFromFinder && input.onboardingCompleted)

        return LaunchBehaviorDecision(
            initialWindowRequest: initialWindowRequest,
            shouldRequestSettingsFromExistingInstance: shouldRequestSettingsFromExistingInstance
        )
    }
}
