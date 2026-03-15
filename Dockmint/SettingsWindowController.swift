import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    @MainActor
    private enum WindowMode {
        case onboarding
        case settings

        var frameDefaultsKey: String {
            switch self {
            case .onboarding:
                return "settingsWindowFrame.onboarding"
            case .settings:
                return "settingsWindowFrame"
            }
        }

        var frameDefaultsVersionKey: String {
            switch self {
            case .onboarding:
                return "settingsWindowFrameVersion.onboarding"
            case .settings:
                return "settingsWindowFrameVersion"
            }
        }

        var frameDefaultsVersion: Int {
            switch self {
            case .onboarding:
                return 2
            case .settings:
                return 2
            }
        }

        var preferredFrameSize: NSSize {
            switch self {
            case .onboarding:
                return NSSize(width: 420, height: 640)
            case .settings:
                return NSSize(width: 873, height: 560)
            }
        }

        var minimumHeight: CGFloat {
            switch self {
            case .onboarding:
                return 600
            case .settings:
                return 380
            }
        }

        var preferredTitle: String {
            switch self {
            case .onboarding:
                return "\(AppServices.appDisplayName) Setup"
            case .settings:
                return AppServices.settingsWindowTitle
            }
        }

        var initialFocusButtonTitles: [String] {
            switch self {
            case .onboarding:
                return ["Finish Setup", "Done", "Open Settings"]
            case .settings:
                return ["Check for Updates", "Show menu bar icon"]
            }
        }
    }

    private static let animationsDisabled: Bool = {
        AppIdentity.boolFlag(
            primary: "DOCKMINT_DISABLE_SETTINGS_ANIMATION",
            legacy: "DOCKTOR_DISABLE_SETTINGS_ANIMATION"
        )
    }()
    private static let automationSectionEnvironmentKey = "DOCKMINT_SETTINGS_AUTOMATION_SECTION"
    private static let legacyAutomationSectionEnvironmentKey = "DOCKTOR_SETTINGS_AUTOMATION_SECTION"

    private let defaults = UserDefaults.standard
    private let preferences: Preferences
    private let folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    private let viewModel: SettingsWindowViewModel
    private let hostingController: NSHostingController<SettingsRootView>
    private var frameObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pendingOpenSession: SettingsPerformance.Session?
    private var pendingPaneSession: SettingsPerformance.Session?
    private var pendingPaneReady: SettingsPane?

    init(services: AppServices) {
        self.preferences = services.preferences
        self.folderOpenWithOptionsStore = services.folderOpenWithOptionsStore
        let viewModel = SettingsWindowViewModel()
        self.viewModel = viewModel
        let rootView = SettingsRootView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences,
            folderOpenWithOptionsStore: services.folderOpenWithOptionsStore,
            viewModel: viewModel,
            onPaneAppear: { _ in },
            onPaneSelectionRequest: { _ in }
        )
        self.hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.toolbarStyle = .preference
        window.setFrame(NSRect(origin: .zero, size: Self.currentMode(for: services.preferences).preferredFrameSize), display: false)

        super.init(window: window)
        window.delegate = self

        hostingController.rootView = SettingsRootView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences,
            folderOpenWithOptionsStore: services.folderOpenWithOptionsStore,
            viewModel: viewModel,
            onPaneAppear: { [weak self] pane in
                self?.paneDidAppear(pane)
            },
            onPaneSelectionRequest: { [weak self] pane in
                self?.paneSelectionRequested(pane)
            }
        )

        folderOpenWithOptionsStore.warmIfNeeded()
        bindPreferenceChanges()
        applyWindowMode(animated: false)
        if !restoreFrame(for: window, mode: mode) {
            center(window: window)
        }
        observeFrameChanges(for: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var mode: WindowMode {
        Self.currentMode(for: preferences)
    }

    private static func currentMode(for preferences: Preferences) -> WindowMode {
        preferences.shouldPresentOnboarding ? .onboarding : .settings
    }

    func show(openSession: SettingsPerformance.Session? = nil) {
        guard let window else { return }
        pendingOpenSession = openSession
        pendingPaneReady = preferences.shouldPresentOnboarding ? nil : (automationRequestedPane() ?? viewModel.selectedPane)

        if window.isVisible, !preferences.shouldPresentOnboarding, automationRequestedPane() == nil {
            pendingOpenSession?.complete(extraMetadata: SettingsPerformance.sectionMetadata(for: viewModel.selectedPane))
            pendingOpenSession = nil
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyInitialKeyboardSelection()
            if self.preferences.shouldPresentOnboarding {
                self.pendingOpenSession?.complete(extraMetadata: ["pane": "onboarding"])
                self.pendingOpenSession = nil
            } else if let automationPane = self.automationRequestedPane() {
                self.pendingPaneSession = SettingsPerformance.begin(
                    .paneSwitch,
                    metadata: SettingsPerformance.sectionMetadata(for: automationPane)
                )
                self.pendingPaneReady = automationPane
                self.selectSection(automationPane, recordPerformance: false)
            } else {
                self.paneDidAppear(self.viewModel.selectedPane)
            }
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in frameObservers {
            center.removeObserver(observer)
        }
    }

    private func bindPreferenceChanges() {
        preferences.$onboardingState
            .map(\.isCompleted)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCompleted in
                guard let self else { return }
                if isCompleted {
                    self.viewModel.selectedPane = .general
                }
                self.applyWindowMode(animated: true)
                DispatchQueue.main.async {
                    self.applyInitialKeyboardSelection()
                    if isCompleted {
                        self.paneDidAppear(.general)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeFrameChanges(for window: NSWindow) {
        let center = NotificationCenter.default
        frameObservers.append(
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window, mode: self?.mode ?? .settings)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window, mode: self?.mode ?? .settings)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window, mode: self?.mode ?? .settings)
                }
            }
        )
    }

    private func paneDidAppear(_ pane: SettingsPane) {
        guard pane == pendingPaneReady else { return }
        pendingPaneReady = nil
        pendingPaneSession?.complete(extraMetadata: SettingsPerformance.sectionMetadata(for: pane))
        pendingPaneSession = nil
        pendingOpenSession?.complete(extraMetadata: SettingsPerformance.sectionMetadata(for: pane))
        pendingOpenSession = nil
    }

    private func paneSelectionRequested(_ pane: SettingsPane) {
        guard !preferences.shouldPresentOnboarding else { return }
        selectSection(pane, recordPerformance: true)
    }

    private func selectSection(_ pane: SettingsPane, recordPerformance: Bool) {
        if recordPerformance {
            pendingPaneSession = SettingsPerformance.begin(
                .paneSwitch,
                metadata: SettingsPerformance.sectionMetadata(for: pane)
            )
            pendingPaneReady = pane
        }

        let selectionChanged = pane != viewModel.selectedPane
        viewModel.selectedPane = pane

        if !selectionChanged {
            DispatchQueue.main.async { [weak self] in
                self?.paneDidAppear(pane)
            }
        }
    }

    private func automationRequestedPane() -> SettingsPane? {
        let environment = ProcessInfo.processInfo.environment
        let rawValue = environment[Self.automationSectionEnvironmentKey]
            ?? environment[Self.legacyAutomationSectionEnvironmentKey]
        guard let rawValue else { return nil }

        switch rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased() {
        case "general":
            return .general
        case "appactions":
            return .appActions
        case "folderactions":
            return .folderActions
        default:
            return nil
        }
    }

    private func applyWindowMode(animated: Bool) {
        guard let window else { return }
        let mode = self.mode
        window.title = mode.preferredTitle
        applyWindowSizing(for: mode, animated: animated)
        if !restoreFrame(for: window, mode: mode) {
            center(window: window)
        }
    }

    private func applyWindowSizing(for mode: WindowMode, animated: Bool) {
        guard let window else { return }

        let frameSize = mode.preferredFrameSize
        let currentFrame = window.frame
        let maxHeight = maximumWindowHeight(for: window, frameSize: frameSize)
        let targetHeight = min(max(currentFrame.height, mode.minimumHeight), maxHeight)
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetHeight,
            width: frameSize.width,
            height: targetHeight
        )

        let minWindowSize = NSSize(width: frameSize.width, height: mode.minimumHeight)
        let maxWindowSize = NSSize(width: frameSize.width, height: maxHeight)
        let minContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minWindowSize)).size
        let maxContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: maxWindowSize)).size

        window.minSize = minWindowSize
        window.maxSize = maxWindowSize
        window.contentMinSize = minContentSize
        window.contentMaxSize = maxContentSize
        window.setFrame(newFrame, display: true, animate: animated && !Self.animationsDisabled)
    }

    private func maximumWindowHeight(for window: NSWindow, frameSize: NSSize) -> CGFloat {
        max(window.screen?.visibleFrame.height ?? 0,
            targetScreen()?.visibleFrame.height ?? 0,
            frameSize.height)
    }

    private func saveFrame(from window: NSWindow, mode: WindowMode) {
        defaults.set(NSStringFromRect(window.frame), forKey: mode.frameDefaultsKey)
        defaults.set(mode.frameDefaultsVersion, forKey: mode.frameDefaultsVersionKey)
    }

    private func restoreFrame(for window: NSWindow, mode: WindowMode) -> Bool {
        guard let frameString = defaults.string(forKey: mode.frameDefaultsKey) else {
            return false
        }
        var frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0, frameIsVisible(frame) else {
            return false
        }
        let defaultSize = mode.preferredFrameSize
        let storedVersion = defaults.integer(forKey: mode.frameDefaultsVersionKey)
        frame.size.width = defaultSize.width
        if storedVersion < mode.frameDefaultsVersion {
            frame.size.height = defaultSize.height
        } else {
            frame.size.height = max(frame.size.height, mode.minimumHeight)
        }
        window.setFrame(frame, display: false)
        return true
    }

    private func frameIsVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
    }

    private func center(window: NSWindow) {
        guard let targetScreen = targetScreen() else {
            window.center()
            return
        }
        let visibleFrame = targetScreen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - (window.frame.width / 2),
            y: visibleFrame.midY - (window.frame.height / 2)
        )
        window.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return hoveredScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let mode = self.mode
        let maxHeight = maximumWindowHeight(for: sender, frameSize: mode.preferredFrameSize)
        return NSSize(width: frameSize.width, height: min(max(frameSize.height, mode.minimumHeight), maxHeight))
    }

    private func applyInitialKeyboardSelection() {
        guard let window, let contentView = window.contentView else { return }
        let button = mode.initialFocusButtonTitles.lazy.compactMap { title in
            self.findButton(in: contentView, titled: title)
        }.first
        guard let button else { return }
        window.defaultButtonCell = button.cell as? NSButtonCell
        window.makeFirstResponder(button)
    }

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(in: subview, titled: title) {
                return button
            }
        }
        return nil
    }
}
