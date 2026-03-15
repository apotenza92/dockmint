import XCTest

@MainActor
final class PreferencesMigrationXCTest: XCTestCase {
    func testLegacyFirstLaunchCompletionMigratesToCompletedOnboarding() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "firstLaunchCompleted")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(preferences.onboardingState, .completed)
        XCTAssertTrue(preferences.isOnboardingCompleted)
    }

    func testLegacyWeeklyDefaultMigratesToOptInDisabled() {
        let defaults = isolatedDefaults()
        defaults.set(UpdateCheckFrequency.weekly.rawValue, forKey: "updateCheckFrequency")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertFalse(preferences.backgroundUpdateChecksEnabled)
        XCTAssertEqual(preferences.updateCheckFrequency, .never)
    }

    func testExplicitLegacyNonDefaultUpdateChoiceIsPreserved() {
        let defaults = isolatedDefaults()
        defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: "updateCheckFrequency")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertTrue(preferences.backgroundUpdateChecksEnabled)
        XCTAssertEqual(preferences.updateCheckFrequency, .daily)
    }

    func testStoredLoginItemPreferenceIsPreservedAcrossMigration() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "startAtLogin")
        defaults.set(true, forKey: "firstLaunchCompleted")
        defaults.set(UpdateCheckFrequency.weekly.rawValue, forKey: "updateCheckFrequency")

        let preferences = Preferences(
            testingUserDefaults: defaults,
            bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier,
            loginItemClient: .init(
                status: { .notRegistered },
                register: {},
                unregister: {}
            )
        )

        XCTAssertTrue(preferences.startAtLogin)
    }

    private func isolatedDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "DockmintTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults", file: file, line: line)
            fatalError("Failed to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
