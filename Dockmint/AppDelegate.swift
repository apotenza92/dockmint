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

    private static var shouldManageOtherRunningIdentityInstances: Bool {
        AppIdentity.isDevelopmentIdentity
    }

    private static var shouldAlwaysShowSettingsOnLaunchForLocalDevelopmentBuild: Bool {
        AppIdentity.isDevelopmentIdentity
            && !AppIdentity.boolFlag(primary: "DOCKMINT_TEST_SUITE", legacy: "DOCKTOR_TEST_SUITE")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Logger.prepareForLaunch()
        migrateInstalledAppBundleNameIfNeeded()
        Logger.log("Launched bundle at \(Bundle.main.bundleURL.path), bundleId \(Bundle.main.bundleIdentifier ?? "nil"), pid \(ProcessInfo.processInfo.processIdentifier), LSUIElement \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)")

        startObservingOpenSettingsRequests()

        let launchRequestsSettings = ProcessInfo.processInfo.arguments.contains { openSettingsLaunchArguments.contains($0) }
        let launchedFromFinder = isFinderLaunch()
        let launchDecision = LaunchBehavior.decide(
            LaunchBehaviorInput(
                isDebugBuild: Self.shouldAlwaysShowSettingsOnLaunchForLocalDevelopmentBuild,
                onboardingCompleted: preferences.isOnboardingCompleted,
                showOnStartup: preferences.showOnStartup,
                launchArgumentsRequestSettings: launchRequestsSettings,
                launchedFromFinder: launchedFromFinder
            )
        )

        if resolveRunningInstances(
            shouldRequestSettingsFromExisting: launchDecision.shouldRequestSettingsFromExistingInstance
        ) {
            return
        }

        menuBarController = MenuBarController(preferences: preferences, appDelegate: self)
        coordinator.startIfPossible()
        coordinator.refreshPermissionsAfterExternalChange()
        updateManager.configureForLaunch(isAutomatedMode: false)

        if launchRequestsSettings {
            Logger.log("Launch argument requested settings window")
        }
        if launchedFromFinder {
            Logger.log("Finder launch detected")
        }
        if Self.shouldAlwaysShowSettingsOnLaunchForLocalDevelopmentBuild {
            Logger.log("Development identity detected; opening settings window on launch")
        }

        DispatchQueue.main.async {
            switch launchDecision.initialWindowRequest {
            case .none:
                break
            case .onboarding:
                self.showSettingsWindow(explicit: false)
            case let .settings(explicit):
                self.showSettingsWindow(explicit: explicit)
            }
        }
    }

    private func isFinderLaunch() -> Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-psn_") }
    }

    @discardableResult
    private func resolveRunningInstances(shouldRequestSettingsFromExisting: Bool) -> Bool {
        guard Self.shouldManageOtherRunningIdentityInstances || shouldRequestSettingsFromExisting else {
            return false
        }

        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != me }
            .filter(isCurrentIdentityApplication)

        guard !others.isEmpty else { return false }

        let sameBundleInstances = others.filter(isSameBundleLocation)
        let otherBundleInstances = others.filter { !isSameBundleLocation($0) }

        if shouldRequestSettingsFromExisting, !sameBundleInstances.isEmpty, otherBundleInstances.isEmpty {
            Logger.log("Existing same-bundle instance detected (\(sameBundleInstances.map { $0.processIdentifier })); requesting settings open in running instance")
            requestSettingsOpenFromExistingInstance()
            NSApp.terminate(nil)
            return true
        }

        guard Self.shouldManageOtherRunningIdentityInstances else {
            Logger.log("Other \(AppServices.appDisplayName) identity instances detected but duplicate-instance management is disabled: \(describeRunningApplications(others))")
            return false
        }

        Logger.log("Terminating other \(AppServices.appDisplayName) identity instances: \(describeRunningApplications(others))")
        terminateRunningApplications(others)
        return false
    }

    private func isCurrentIdentityApplication(_ app: NSRunningApplication) -> Bool {
        if let bundleIdentifier = app.bundleIdentifier,
           AppIdentity.instanceBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        if let localizedName = app.localizedName,
           AppIdentity.instanceAppNames.contains(localizedName) {
            return true
        }

        guard let bundleURL = app.bundleURL?.standardizedFileURL else {
            return false
        }

        if AppIdentity.instanceBundleNames.contains(bundleURL.lastPathComponent) {
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
            return AppIdentity.instanceAppNames.contains(value)
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
                    self.showSettingsWindow(explicit: true)
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
        showSettingsWindow(explicit: true)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshPermissionsAfterExternalChange()
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
            showSettingsWindow(explicit: true)
        }
    }

    func showSettingsWindow(explicit: Bool = false) {
        if explicit {
            restoreMenuBarIconIfNeeded()
        }
        Logger.log("Opening settings window explicit=\(explicit) onboardingIncomplete=\(!preferences.isOnboardingCompleted)")
        coordinator.refreshPermissionsAfterExternalChange()
        let openSession = SettingsPerformance.begin(.settingsOpen)
        settingsWindowController.show(openSession: openSession)
    }
}
