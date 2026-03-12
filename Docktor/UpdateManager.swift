import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager(preferences: Preferences.shared)

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var currentVersionText = UpdateManager.makeCurrentVersionText()
    @Published private(set) var updateStatusText = "Update status unavailable."

    private let preferences: Preferences
    private var updateCheckTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var didConfigure = false
    private var isCheckingForUpdates = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    func configureForLaunch(isAutomatedMode: Bool) {
        guard !didConfigure else { return }
        didConfigure = true

        guard !isAutomatedMode else {
            Logger.log("UpdateManager disabled in automated test mode")
            updateStatusText = "Update checks disabled in automated test mode."
            return
        }

        guard !Self.isDevelopmentBuild else {
            Logger.log("UpdateManager disabled in development build")
            canCheckForUpdates = false
            updateStatusText = "Update checks disabled in development builds."
            return
        }

        updaterController.startUpdater()
        bindUpdaterState()
        bindPreferences()
        updateStatusText = "Ready to check for updates."
        performLaunchUpdateCheckIfNeeded()
        rescheduleAutomaticChecks()
    }

    func checkForUpdates() {
        guard didConfigure else { return }
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
        beginUpdateCheck(statusText: "Checking for updates...")
        updaterController.checkForUpdates(nil)
    }

    private func bindUpdaterState() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    private func bindPreferences() {
        preferences.$updateCheckFrequency
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rescheduleAutomaticChecks()
            }
            .store(in: &cancellables)
    }

    private func performLaunchUpdateCheckIfNeeded() {
        guard preferences.shouldCheckForUpdatesOnLaunch() else { return }
        performBackgroundUpdateCheck()
    }

    private func rescheduleAutomaticChecks() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        guard let interval = preferences.updateCheckFrequency.interval else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performBackgroundUpdateCheck()
            }
        }
        timer.tolerance = min(300, interval * 0.15)
        updateCheckTimer = timer
    }

    private func performBackgroundUpdateCheck() {
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
        beginUpdateCheck(statusText: "Checking for updates...")
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func beginUpdateCheck(statusText: String) {
        isCheckingForUpdates = true
        updateStatusText = statusText
    }

    private func finishUpdateCheckIfNeeded() {
        isCheckingForUpdates = false
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let base = "https://raw.githubusercontent.com/apotenza92/docktor/main/appcasts"
        let channel = Self.isBetaBuild ? "beta" : "stable"
        let arch = Self.architectureSuffix
        return "\(base)/\(channel)-\(arch).xml"
    }

    nonisolated private static var isBetaBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
    }

    nonisolated private static var architectureSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    nonisolated private static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func makeCurrentVersionText() -> String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (.some(shortVersion), .some(buildVersion)) where !shortVersion.isEmpty && !buildVersion.isEmpty:
            return "Version \(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), _ ) where !shortVersion.isEmpty:
            return "Version \(shortVersion)"
        case let (_, .some(buildVersion)) where !buildVersion.isEmpty:
            return "Build \(buildVersion)"
        default:
            return "Version unavailable"
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finishUpdateCheckIfNeeded()
        updateStatusText = "Update available: \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        finishUpdateCheckIfNeeded()
        updateStatusText = "You're up to date."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        finishUpdateCheckIfNeeded()
        updateStatusText = "You're up to date."
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        finishUpdateCheckIfNeeded()
        updateStatusText = "Installing update \(item.displayVersionString)..."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finishUpdateCheckIfNeeded()
        updateStatusText = "Update check failed: \(error.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            finishUpdateCheckIfNeeded()
            updateStatusText = "Update check failed: \(error.localizedDescription)"
            return
        }

        guard isCheckingForUpdates else { return }
        finishUpdateCheckIfNeeded()
        updateStatusText = "Update check finished."
    }
}
