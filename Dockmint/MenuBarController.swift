import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let preferences: Preferences
    private weak var appDelegate: AppDelegate?
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private let appDisplayName = AppServices.appDisplayName

    init(preferences: Preferences, appDelegate: AppDelegate) {
        #if DEBUG
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        #else
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #endif
        self.preferences = preferences
        self.appDelegate = appDelegate
        super.init()
        configureStatusItem()
        configureMenu()
        observePreferences()
        applyVisibility(preferences.showMenuBarIcon)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = StatusBarIcon.image()
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(appDisplayName)
    }

    private func configureMenu() {
        let settingsItem = NSMenuItem(
            title: "\(appDisplayName) Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appDisplayName)",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func observePreferences() {
        preferences.$showMenuBarIcon
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showIcon in
                self?.applyVisibility(showIcon)
            }
            .store(in: &cancellables)
    }

    private func applyVisibility(_ visible: Bool) {
        let runningAutomation: Bool
        #if DEBUG
        runningAutomation = AppIdentity.boolFlag(
            primary: "DOCKMINT_TEST_SUITE",
            legacy: "DOCKTOR_TEST_SUITE"
        )
        let shouldShow = runningAutomation ? visible : true
        #else
        runningAutomation = false
        let shouldShow = visible
        #endif
        statusItem.menu = shouldShow ? menu : nil
        statusItem.isVisible = shouldShow
        Logger.log(
            "Menu bar icon visibility applied: requested=\(visible) effective=\(shouldShow) testSuite=\(runningAutomation)"
        )
    }

    @objc
    private func openSettings() {
        appDelegate?.showSettingsWindow()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}
