import XCTest

final class LaunchBehaviorXCTest: XCTestCase {
    func testFreshLaunchOpensOnboarding() {
        let decision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: false,
                onboardingCompleted: false,
                showOnStartup: false,
                launchArgumentsRequestSettings: false,
                launchedFromFinder: true
            )
        )

        XCTAssertEqual(decision.initialWindowRequest, .onboarding)
        XCTAssertFalse(decision.shouldRequestSettingsFromExistingInstance)
    }

    func testFinderLaunchDoesNotOpenSettingsForExistingUser() {
        let decision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: false,
                onboardingCompleted: true,
                showOnStartup: false,
                launchArgumentsRequestSettings: false,
                launchedFromFinder: true
            )
        )

        XCTAssertEqual(decision.initialWindowRequest, .none)
        XCTAssertFalse(decision.shouldShowWindow)
        XCTAssertTrue(decision.shouldRequestSettingsFromExistingInstance)
    }

    func testFreshFinderLaunchDoesNotRequestSettingsFromExistingInstance() {
        let decision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: false,
                onboardingCompleted: false,
                showOnStartup: false,
                launchArgumentsRequestSettings: false,
                launchedFromFinder: true
            )
        )

        XCTAssertEqual(decision.initialWindowRequest, .onboarding)
        XCTAssertFalse(decision.shouldRequestSettingsFromExistingInstance)
    }

    func testExplicitSettingsLaunchStillOpensSettings() {
        let decision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: false,
                onboardingCompleted: true,
                showOnStartup: false,
                launchArgumentsRequestSettings: true,
                launchedFromFinder: false
            )
        )

        XCTAssertEqual(decision.initialWindowRequest, .settings(explicit: true))
        XCTAssertTrue(decision.shouldRequestSettingsFromExistingInstance)
    }

    func testDebugBuildStillAutoOpensSettings() {
        let decision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: true,
                onboardingCompleted: true,
                showOnStartup: false,
                launchArgumentsRequestSettings: false,
                launchedFromFinder: false
            )
        )

        XCTAssertEqual(decision.initialWindowRequest, .settings(explicit: false))
        XCTAssertTrue(decision.shouldShowWindow)
    }
}
