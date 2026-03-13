import XCTest

@MainActor
final class DockFolderActionTests: XCTestCase {
    func testFreshPreferencesDefaultFolderClickUsesFinderPassthrough() {
        let preferences = makePreferences()

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertTrue(preferences.folderClickAction.isFinderPassthrough)
        XCTAssertEqual(
            preferences.folderClickAction.openInApplicationIdentifier,
            DockFolderOpenApplicationCatalog.finderBundleIdentifier
        )
    }

    func testResetFolderActionsRestoresFinderPassthroughDefault() {
        let preferences = makePreferences()
        preferences.folderClickAction = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .list,
            sortBy: .name,
            groupBy: .none
        )

        preferences.resetFolderActionsToDefaults()

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertTrue(preferences.folderClickAction.isFinderPassthrough)
    }

    func testLegacyStoredDockDefaultMigratesToFinderPassthrough() {
        let defaults = isolatedDefaults()
        let legacyDefault = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        defaults.set(legacyDefault.storageValue, forKey: "folderClickAction")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertEqual(defaults.string(forKey: "folderClickAction"), Preferences.defaultFolderClickAction.storageValue)
    }

    func testFinderPassthroughRequiresFinderAndAutomaticViewOnly() {
        let finderAutomatic = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        let finderList = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .none,
            groupBy: .none
        )
        let customAutomatic = DockFolderAction(
            openInApplicationIdentifier: "com.apple.Terminal",
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )

        XCTAssertTrue(finderAutomatic.isFinderPassthrough)
        XCTAssertFalse(finderList.isFinderPassthrough)
        XCTAssertFalse(customAutomatic.isFinderPassthrough)
    }

    func testExplicitFinderOverridesAreNotPassthrough() {
        let explicitView = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .icon,
            sortBy: .none,
            groupBy: .none
        )
        let explicitGroup = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .name,
            groupBy: .kind
        )

        XCTAssertFalse(explicitView.isFinderPassthrough)
        XCTAssertFalse(explicitGroup.isFinderPassthrough)
    }

    func testExecutionRouteClassificationCoversAllFolderActionBranches() {
        XCTAssertEqual(DockFolderActionExecutor.executionRoute(for: .none), .none)
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
                    view: .automatic,
                    sortBy: .none,
                    groupBy: .none
                )
            ),
            .dock
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(for: Preferences.defaultFolderClickAction),
            .finderPassthrough
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                    view: .list,
                    sortBy: .name,
                    groupBy: .none
                )
            ),
            .finderScripted
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: "com.apple.Terminal",
                    view: .automatic,
                    sortBy: .none,
                    groupBy: .none
                )
            ),
            .customApplication
        )
    }

    private func makePreferences() -> Preferences {
        Preferences(testingUserDefaults: isolatedDefaults())
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
