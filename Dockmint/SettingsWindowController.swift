import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static let animationsDisabled: Bool = {
        AppIdentity.boolFlag(
            primary: "DOCKMINT_DISABLE_SETTINGS_ANIMATION",
            legacy: "DOCKTOR_DISABLE_SETTINGS_ANIMATION"
        )
    }()
    private let defaults = UserDefaults.standard
    private let frameDefaultsKey = "settingsWindowFrame"
    private let frameDefaultsVersionKey = "settingsWindowFrameVersion"
    private let currentFrameDefaultsVersion = 2
    private let primaryInitialFocusControlTitle = "Show menu bar icon"
    private let fallbackInitialFocusControlTitle = "Check for Updates"
    private let folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    private let viewModel: SettingsWindowViewModel
    private let hostingController: NSHostingController<PreferencesView>
    private var frameObservers: [NSObjectProtocol] = []
    private var pendingOpenSession: SettingsPerformance.Session?
    private var pendingPaneSession: SettingsPerformance.Session?
    private var pendingPaneReady: SettingsPane?

    init(services: AppServices) {
        self.folderOpenWithOptionsStore = services.folderOpenWithOptionsStore
        let viewModel = SettingsWindowViewModel()
        self.viewModel = viewModel
        let view = Self.makePreferencesView(services: services, viewModel: viewModel, onPaneAppear: { _ in })
        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        let window = NSWindow(contentViewController: hostingController)

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = AppServices.settingsWindowTitle
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.toolbarStyle = .preference
        window.setFrame(NSRect(origin: .zero, size: viewModel.selectedPane.windowFrameSize), display: false)

        super.init(window: window)
        window.delegate = self

        hostingController.rootView = Self.makePreferencesView(
            services: services,
            viewModel: viewModel,
            onPaneAppear: { [weak self] pane in
                self?.paneDidAppear(pane)
            }
        )

        folderOpenWithOptionsStore.warmIfNeeded()
        applyWindowSizing(for: viewModel.selectedPane, animated: false)
        if !restoreFrame(for: window) {
            center(window: window)
        }
        observeFrameChanges(for: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(openSession: SettingsPerformance.Session? = nil) {
        guard let window else { return }
        pendingOpenSession = openSession
        pendingPaneReady = viewModel.selectedPane

        if window.isVisible {
            pendingOpenSession?.complete(extraMetadata: ["pane": viewModel.selectedPane.rawValue])
            pendingOpenSession = nil
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.applyInitialKeyboardSelection()
            self?.paneDidAppear(self?.viewModel.selectedPane ?? .general)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in frameObservers {
            center.removeObserver(observer)
        }
    }

    private func observeFrameChanges(for window: NSWindow) {
        let center = NotificationCenter.default
        frameObservers.append(
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
    }

    private func paneDidAppear(_ pane: SettingsPane) {
        guard pane == pendingPaneReady else { return }

        pendingPaneReady = nil
        pendingPaneSession?.complete(extraMetadata: ["pane": pane.rawValue])
        pendingPaneSession = nil
        pendingOpenSession?.complete(extraMetadata: ["pane": pane.rawValue])
        pendingOpenSession = nil
    }

    private static func makePreferencesView(
        services: AppServices,
        viewModel: SettingsWindowViewModel,
        onPaneAppear: @escaping (SettingsPane) -> Void
    ) -> PreferencesView {
        PreferencesView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences,
            folderOpenWithOptionsStore: services.folderOpenWithOptionsStore,
            viewModel: viewModel,
            onPaneAppear: onPaneAppear
        )
    }

    private func applyWindowSizing(for pane: SettingsPane, animated: Bool) {
        guard let window else { return }

        let frameSize = pane.windowFrameSize
        let currentFrame = window.frame
        let minHeight = minimumWindowHeight
        let maxHeight = maximumWindowHeight(for: window, frameSize: frameSize)
        let targetHeight = min(max(currentFrame.height, minHeight), maxHeight)
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetHeight,
            width: frameSize.width,
            height: targetHeight
        )

        let minWindowSize = NSSize(width: frameSize.width, height: minHeight)
        let maxWindowSize = NSSize(width: frameSize.width, height: maxHeight)
        let minContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minWindowSize)).size
        let maxContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: maxWindowSize)).size

        window.minSize = minWindowSize
        window.maxSize = maxWindowSize
        window.contentMinSize = minContentSize
        window.contentMaxSize = maxContentSize
        window.setFrame(newFrame, display: true, animate: animated && !Self.animationsDisabled)
    }

    private var minimumWindowHeight: CGFloat { 380 }

    private func maximumWindowHeight(for window: NSWindow, frameSize: NSSize) -> CGFloat {
        max(window.screen?.visibleFrame.height ?? 0,
            targetScreen()?.visibleFrame.height ?? 0,
            frameSize.height)
    }

    private func saveFrame(from window: NSWindow) {
        defaults.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey)
        defaults.set(currentFrameDefaultsVersion, forKey: frameDefaultsVersionKey)
    }

    private func restoreFrame(for window: NSWindow) -> Bool {
        guard let frameString = defaults.string(forKey: frameDefaultsKey) else {
            return false
        }
        var frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0, frameIsVisible(frame) else {
            return false
        }
        let defaultSize = viewModel.selectedPane.windowFrameSize
        let storedVersion = defaults.integer(forKey: frameDefaultsVersionKey)
        frame.size.width = defaultSize.width
        if storedVersion < currentFrameDefaultsVersion {
            frame.size.height = defaultSize.height
        } else {
            frame.size.height = max(frame.size.height, minimumWindowHeight)
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
        let minHeight = minimumWindowHeight
        let maxHeight = maximumWindowHeight(for: sender, frameSize: viewModel.selectedPane.windowFrameSize)
        return NSSize(width: frameSize.width, height: min(max(frameSize.height, minHeight), maxHeight))
    }

    private func applyInitialKeyboardSelection() {
        guard let window, let contentView = window.contentView else { return }
        let button = findButton(in: contentView, titled: primaryInitialFocusControlTitle)
            ?? findButton(in: contentView, titled: fallbackInitialFocusControlTitle)
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

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsGeneral, .settingsAppActions, .settingsFolderActions]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsGeneral, .settingsAppActions, .settingsFolderActions]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsGeneral, .settingsAppActions, .settingsFolderActions]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let pane: SettingsPane
        switch itemIdentifier {
        case .settingsGeneral:
            pane = .general
        case .settingsAppActions:
            pane = .appActions
        case .settingsFolderActions:
            pane = .folderActions
        default:
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPaneFromToolbar(_:))
        return item
    }

    @objc
    private func selectPaneFromToolbar(_ sender: NSToolbarItem) {
        guard let window else { return }

        let pane: SettingsPane
        switch sender.itemIdentifier {
        case .settingsGeneral:
            pane = .general
        case .settingsAppActions:
            pane = .appActions
        case .settingsFolderActions:
            pane = .folderActions
        default:
            return
        }

        guard pane != viewModel.selectedPane else { return }

        pendingPaneSession = SettingsPerformance.begin(.paneSwitch, metadata: ["pane": pane.rawValue])
        pendingPaneReady = pane
        viewModel.selectedPane = pane
        window.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        applyWindowSizing(for: pane, animated: true)
        DispatchQueue.main.async { [weak self] in
            self?.paneDidAppear(pane)
        }
    }
}

private extension NSToolbar.Identifier {
    static let settingsToolbar = NSToolbar.Identifier("DockmintSettingsToolbar")
}

private extension NSToolbarItem.Identifier {
    static let settingsGeneral = NSToolbarItem.Identifier("DockmintSettingsGeneral")
    static let settingsAppActions = NSToolbarItem.Identifier("DockmintSettingsAppActions")
    static let settingsFolderActions = NSToolbarItem.Identifier("DockmintSettingsFolderActions")
}
