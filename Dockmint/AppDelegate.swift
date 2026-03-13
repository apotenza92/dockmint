import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var services: AppServices = .live

    private var coordinator: DockExposeCoordinator { Self.services.coordinator }
    private var preferences: Preferences { Self.services.preferences }
    private var updateManager: UpdateManager { Self.services.updateManager }
    private lazy var settingsWindowController = SettingsWindowController(services: Self.services)
    private var menuBarController: MenuBarController?
    private let openSettingsLaunchArguments: Set<String> = ["--settings", "-settings", "--open-settings"]
    private var openSettingsObservers: [NSObjectProtocol] = []

    private static var shouldManageOtherDockmintInstances: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static var shouldAlwaysShowSettingsOnLaunchForLocalDebugBuild: Bool {
        #if DEBUG
        return !AppIdentity.boolFlag(primary: "DOCKMINT_TEST_SUITE", legacy: "DOCKTOR_TEST_SUITE")
        #else
        return false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateInstalledAppBundleNameIfNeeded()
        Logger.log("Launched bundle at \(Bundle.main.bundleURL.path), bundleId \(Bundle.main.bundleIdentifier ?? "nil"), pid \(ProcessInfo.processInfo.processIdentifier), LSUIElement \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)")

        startObservingOpenSettingsRequests()

        let launchRequestsSettings = ProcessInfo.processInfo.arguments.contains { openSettingsLaunchArguments.contains($0) }
        let launchedFromFinder = isFinderLaunch()
        let explicitSettingsRequest = launchRequestsSettings || launchedFromFinder

        // Important: do NOT hand off Finder launches to an existing instance.
        // Sparkle relaunches and in-app restart flows also look like Finder launches (`-psn_`),
        // and handing those off can cause the freshly launched process to exit.
        let shouldRequestSettingsFromExisting = launchRequestsSettings

        if resolveRunningInstances(shouldRequestSettingsFromExisting: shouldRequestSettingsFromExisting) {
            return
        }

        menuBarController = MenuBarController(preferences: preferences, appDelegate: self)
        coordinator.startIfPossible()
        updateManager.configureForLaunch(isAutomatedMode: false)

        let isFirstLaunch = !preferences.firstLaunchCompleted
        let shouldShowWindow = explicitSettingsRequest
            || isFirstLaunch
            || preferences.showOnStartup
            || Self.shouldAlwaysShowSettingsOnLaunchForLocalDebugBuild
        if launchRequestsSettings {
            Logger.log("Launch argument requested settings window")
        }
        if launchedFromFinder {
            Logger.log("Finder launch detected")
        }
        if Self.shouldAlwaysShowSettingsOnLaunchForLocalDebugBuild {
            Logger.log("Local Debug build detected; opening settings window on launch")
        }

        DispatchQueue.main.async {
            if explicitSettingsRequest {
                self.restoreMenuBarIconIfNeeded()
            }
            if shouldShowWindow {
                self.showSettingsWindow()
            }
            self.handlePermissionsIfNeeded(allowPrompt: shouldShowWindow)
            if isFirstLaunch {
                self.preferences.firstLaunchCompleted = true
            }
        }
    }

    private func isFinderLaunch() -> Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-psn_") }
    }

    @discardableResult
    private func resolveRunningInstances(shouldRequestSettingsFromExisting: Bool) -> Bool {
        guard Self.shouldManageOtherDockmintInstances || shouldRequestSettingsFromExisting else {
            return false
        }

        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != me }
            .filter(isDockmintFamilyApplication)

        guard !others.isEmpty else { return false }

        let sameBundleInstances = others.filter(isSameBundleLocation)
        let otherBundleInstances = others.filter { !isSameBundleLocation($0) }

        if shouldRequestSettingsFromExisting, !sameBundleInstances.isEmpty, otherBundleInstances.isEmpty {
            Logger.log("Existing same-bundle instance detected (\(sameBundleInstances.map { $0.processIdentifier })); requesting settings open in running instance")
            requestSettingsOpenFromExistingInstance()
            NSApp.terminate(nil)
            return true
        }

        guard Self.shouldManageOtherDockmintInstances else {
            Logger.log("Other Dockmint-family instances detected but duplicate-instance management is disabled for this build: \(describeRunningApplications(others))")
            return false
        }

        Logger.log("Terminating other Dockmint instances: \(describeRunningApplications(others))")
        terminateRunningApplications(others)
        return false
    }

    private func isDockmintFamilyApplication(_ app: NSRunningApplication) -> Bool {
        if let bundleIdentifier = app.bundleIdentifier,
           AppIdentity.familyBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        if let localizedName = app.localizedName,
           AppIdentity.familyAppNames.contains(localizedName) {
            return true
        }

        guard let bundleURL = app.bundleURL?.standardizedFileURL else {
            return false
        }

        let appBundleNames = AppIdentity.legacyAppBundleNames.union([AppIdentity.stableBundleName, AppIdentity.betaBundleName])
        if appBundleNames.contains(bundleURL.lastPathComponent) {
            return true
        }

        guard let bundle = Bundle(url: bundleURL) else {
            return false
        }

        let bundleMetadata = [
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        ]

        return bundleMetadata.contains { value in
            guard let value else { return false }
            return AppIdentity.familyAppNames.contains(value)
        }
    }

    private func isSameBundleLocation(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL?.standardizedFileURL else { return false }
        return bundleURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func describeRunningApplications(_ apps: [NSRunningApplication]) -> String {
        apps.map { app in
            let name = app.localizedName ?? "unknown"
            let bundleIdentifier = app.bundleIdentifier ?? "nil"
            let path = app.bundleURL?.path ?? "unknown"
            return "\(name)(pid=\(app.processIdentifier), bundleId=\(bundleIdentifier), path=\(path))"
        }
        .joined(separator: ", ")
    }

    private func terminateRunningApplications(_ apps: [NSRunningApplication]) {
        for app in apps {
            let terminateRequested = app.terminate()
            if waitForTermination(of: app, timeout: 2.0) {
                continue
            }

            Logger.log("Dockmint instance pid \(app.processIdentifier) did not quit after terminate(requested=\(terminateRequested)); forcing termination")
            let forced = app.forceTerminate()
            if waitForTermination(of: app, timeout: 1.0) {
                continue
            }

            Logger.log("Dockmint instance pid \(app.processIdentifier) still running after forceTerminate(requested=\(forced))")
        }
    }

    private func waitForTermination(of app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        if app.isTerminated {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return app.isTerminated
    }

    private func startObservingOpenSettingsRequests() {
        guard openSettingsObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let observedObject = Bundle.main.bundleIdentifier
        for notificationName in AppIdentity.settingsNotificationNames {
            let observer = center.addObserver(
                forName: notificationName,
                object: observedObject,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    Logger.log("Received distributed settings-open request")
                    self.restoreMenuBarIconIfNeeded()
                    self.showSettingsWindow()
                }
            }
            openSettingsObservers.append(observer)
        }
    }

    private func requestSettingsOpenFromExistingInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let center = DistributedNotificationCenter.default()
        for notificationName in AppIdentity.settingsNotificationNames {
            center.postNotificationName(
                notificationName,
                object: bundleId,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    private func restoreMenuBarIconIfNeeded() {
        guard !preferences.showMenuBarIcon else { return }
        Logger.log("Restoring menu bar icon visibility after explicit settings request")
        preferences.showMenuBarIcon = true
    }

    private func migrateInstalledAppBundleNameIfNeeded() {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let currentName = currentBundleURL.lastPathComponent
        let destinationBundleName = AppIdentity.currentAppBundleName

        guard currentName != destinationBundleName else { return }
        guard AppIdentity.legacyAppBundleNames.contains(currentName) else { return }

        let destinationURL = currentBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(destinationBundleName, isDirectory: true)
            .standardizedFileURL
        guard destinationURL.path != currentBundleURL.path else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            Logger.log("Legacy app rename skipped: destination already exists at \(destinationURL.path)")
            return
        }

        do {
            try fileManager.moveItem(at: currentBundleURL, to: destinationURL)
            Logger.log("Renamed installed app bundle from \(currentName) to \(destinationBundleName)")
        } catch {
            Logger.log("Installed app rename failed from \(currentName) to \(destinationBundleName): \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !openSettingsObservers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for observer in openSettingsObservers {
                center.removeObserver(observer)
            }
            openSettingsObservers.removeAll()
        }
        coordinator.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Logger.log("Received app reopen request")
        restoreMenuBarIconIfNeeded()
        showSettingsWindow()
        return false
    }

    private func handlePermissionsIfNeeded(allowPrompt: Bool) {
        let needsAccessibility = !coordinator.hasAccessibilityPermission
        let needsInputMonitoring = !coordinator.inputMonitoringGranted
        guard needsAccessibility || needsInputMonitoring else { return }

        if allowPrompt && needsAccessibility {
            coordinator.requestAccessibilityPermission()
        }

        if allowPrompt && needsInputMonitoring {
            let delay: TimeInterval = needsAccessibility ? 0.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.coordinator.requestInputMonitoringPermission()
                self.coordinator.startWhenPermissionAvailable()
            }
        } else {
            coordinator.startWhenPermissionAvailable()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), AppIdentity.acceptsURLScheme(scheme) else {
            return
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "settings" || host == "preferences" || path == "/settings" || path == "/preferences" {
            Logger.log("Received URL request to open settings: \(url.absoluteString)")
            restoreMenuBarIconIfNeeded()
            showSettingsWindow()
        }
    }

    func showSettingsWindow() {
        Logger.log("Opening settings window")
        let openSession = SettingsPerformance.begin(.settingsOpen)
        settingsWindowController.show(openSession: openSession)
    }
}
