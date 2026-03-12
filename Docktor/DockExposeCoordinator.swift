import AppKit
import Combine
import ApplicationServices

@MainActor
final class DockExposeCoordinator: ObservableObject {
    static let shared = DockExposeCoordinator(preferences: Preferences.shared)

    private let eventTap = DockClickEventTap()
    private let invoker = AppExposeInvoker()
    private let preferences: Preferences
    private var workspaceActivationObserver: NSObjectProtocol?
    private var permissionPollTask: Task<Void, Never>?
    private var lastTriggeredBundle: String? // Track which app we last triggered Exposé for - ignore clicks on same app until different app is clicked
    private var currentExposeApp: String? // Track which app's windows are currently being shown in App Exposé (can differ from lastTriggeredBundle)
    private var appsWithoutWindowsInExpose: Set<String> = [] // Track apps clicked in App Exposé that have no windows
    private var lastExposeDockClickBundle: String? // Last Dock icon click while Exposé tracking was active
    private var lastExposeInteractionAt: Date?
    private var lastScrollBundle: String?
    private var lastScrollDirection: ScrollDirection?
    private var lastScrollTime: TimeInterval?
    private var lastScrollToggleTime: [String: TimeInterval] = [:]
    private let scrollToggleCooldown: TimeInterval = 0.7
    private var lastMinimizeToggleTime: [String: TimeInterval] = [:]
    private let minimizeToggleCooldown: TimeInterval = 1.0
    private var lastHideOthersTargetBundle: String?
    private var pendingClickContext: PendingClickContext?
    private var pendingClickWasDragged = false
    private var pendingFolderClickContext: PendingFolderClickContext?
    private var pendingFolderClickWasDragged = false
    private var appExposeInvocationToken: UUID?
    private var clickRecoveryTokenCounter: UInt64 = 0
    private var clickSequenceCounter: UInt64 = 0
    private var activationAssertionTokenCounter: UInt64 = 0
    private var exposeTrackingExpiryTokenCounter: UInt64 = 0
    private var pendingDockClickWatchdogTokenCounter: UInt64 = 0
    private var consumedFollowUpClickWatchdogTokenCounter: UInt64 = 0
    private var deferredModifierFirstClickTokenCounter: UInt64 = 0
    private let appExposeDismissGraceWindow: TimeInterval = 0.02
    private let exposeTrackingExpiryWindow: TimeInterval = 0.9

    init(preferences: Preferences) {
        self.preferences = preferences
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let activatedBundle = app.bundleIdentifier else { return }
            Task { @MainActor [weak self, activatedBundle] in
                self?.handleWorkspaceActivation(bundleIdentifier: activatedBundle)
            }
        }
    }

    deinit {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted = CGPreflightListenEventAccess()
    @Published private(set) var secureEventInputEnabled = SecureEventInput.isEnabled()

    // Diagnostics
    @Published private(set) var lastStartError: String?
    @Published private(set) var tapEventsSeen: Int = 0
    @Published private(set) var tapClicksSeen: Int = 0
    @Published private(set) var tapScrollsSeen: Int = 0
    @Published private(set) var lastTapEventAt: Date?
    @Published private(set) var lastTapEventType: String?
    @Published private(set) var lastDockBundleHit: String?
    @Published private(set) var lastDockBundleHitAt: Date?
    @Published var diagnosticsCaptureActive: Bool = false

    @Published private(set) var lastActionExecuted: DockAction?
    @Published private(set) var lastActionExecutedBundle: String?
    @Published private(set) var lastActionExecutedSource: String?
    @Published private(set) var lastActionExecutedAt: Date?

    private struct PendingClickContext {
        let clickSequence: UInt64
        let mouseDownUptime: TimeInterval
        let location: CGPoint
        let buttonNumber: Int
        let flags: CGEventFlags
        let frontmostBefore: String?
        let clickedBundle: String
        let windowCountAtMouseDown: Int?
        let followsFirstClickActivation: Bool
        let followsDeferredModifierFirstClick: Bool
        let consumeClick: Bool
        let forceFirstClickActivateFallback: Bool
    }

    private struct PendingFolderClickContext {
        let location: CGPoint
        let buttonNumber: Int
        let flags: CGEventFlags
        let folderURL: URL
        let consumeMouseUp: Bool
    }

    private struct DeferredAppExposeContext {
        let source: String
        let origin: CGPoint?
    }

    private struct DeferredModifierFirstClickContext {
        let token: UInt64
        let location: CGPoint
        let flags: CGEventFlags
        let frontmostBefore: String?
        let clickedBundle: String
        let action: DockAction
        let queuedAt: Date
    }

    private var deferredModifierFirstClickContext: DeferredModifierFirstClickContext?

    var isAppExposeShortcutConfigured: Bool {
        invoker.isApplicationWindowsHotKeyConfigured()
    }

    var isEnabled: Bool {
        isRunning && accessibilityGranted && inputMonitoringGranted
    }

    // Backwards compatibility for callers expecting this name.
    var hasAccessibilityPermission: Bool {
        accessibilityGranted
    }

    func refreshPermissionsAndSecurityState() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        secureEventInputEnabled = SecureEventInput.isEnabled()
    }

    func startIfPossible() {
        refreshPermissionsAndSecurityState()
        guard accessibilityGranted else {
            Logger.log("startIfPossible: denied (no accessibility).")
            return
        }
        guard inputMonitoringGranted else {
            Logger.log("startIfPossible: denied (no input monitoring).")
            return
        }
        if secureEventInputEnabled {
            Logger.log("startIfPossible: Secure Event Input is enabled; synthetic hotkeys may be ignored.")
        }
        guard !isRunning else {
            Logger.log("startIfPossible: already running.")
            return
        }
        lastStartError = nil
        isRunning = eventTap.start(
            clickHandler: { [weak self] point, button, flags, phase in
                return self?.handleClick(at: point, buttonNumber: button, flags: flags, phase: phase) ?? false
            },
            scrollHandler: { [weak self] point, direction, flags in
                return self?.handleScroll(at: point, direction: direction, flags: flags) ?? false
            },
            anyEventHandler: { [weak self] type in
                self?.recordTapEvent(type)
            },
            tapTimeoutHandler: { [weak self] in
                self?.handleEventTapTimeout()
            }
        )
        if !isRunning {
            lastStartError = eventTap.lastStartError
            Logger.log("Failed to start event tap. error=\(lastStartError ?? "unknown")")
        } else {
            Logger.log("Event tap started.")
        }
    }

    func stop() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
        clearDeferredModifierFirstClickContext()
        eventTap.stop()
        isRunning = false
        Logger.log("Event tap stopped.")
    }

    private enum Edge { case bottom, left, right }

    private func dockTargetNearPoint(_ point: CGPoint) -> DockHitTest.PointKind? {
        let candidates = [
            point,
            CGPoint(x: point.x - 10, y: point.y - 10),
            CGPoint(x: point.x, y: point.y - 10),
            CGPoint(x: point.x + 10, y: point.y - 10),
            CGPoint(x: point.x - 10, y: point.y),
            CGPoint(x: point.x + 10, y: point.y),
            CGPoint(x: point.x - 10, y: point.y + 10),
            CGPoint(x: point.x, y: point.y + 10),
            CGPoint(x: point.x + 10, y: point.y + 10)
        ]

        for candidate in candidates {
            let kind = DockHitTest.pointKind(at: candidate)
            switch kind {
            case .appDockIcon, .folderDockItem:
                return kind
            case .dockBackground, .outsideDock:
                continue
            }
        }

        return nil
    }

    private func bundleIdentifierNearPoint(_ point: CGPoint) -> String? {
        if case let .appDockIcon(bundle)? = dockTargetNearPoint(point) {
            return bundle
        }
        return nil
    }

    private func folderURLNearPoint(_ point: CGPoint) -> URL? {
        if case let .folderDockItem(url)? = dockTargetNearPoint(point) {
            return url
        }
        return nil
    }

    private func probeEdgeForBundle(bounds: CGRect,
                                    edge: Edge,
                                    bundleIdentifier: String,
                                    deadline: Date? = nil) -> CGPoint? {
        let margin: CGFloat = 10
        let step: CGFloat = 16
        let startInset: CGFloat = 40
        let depth: CGFloat = 240
        let depthStep: CGFloat = 8

        switch edge {
        case .bottom:
            var y = bounds.maxY - margin
            while y > bounds.maxY - depth {
                if let deadline, Date() > deadline { return nil }
                var x = bounds.minX + startInset
                while x < bounds.maxX - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    x += step
                }
                y -= depthStep
            }
        case .left:
            var x = bounds.minX + margin
            while x < bounds.minX + depth {
                if let deadline, Date() > deadline { return nil }
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    y += step
                }
                x += depthStep
            }
        case .right:
            var x = bounds.maxX - margin
            while x > bounds.maxX - depth {
                if let deadline, Date() > deadline { return nil }
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    y += step
                }
                x -= depthStep
            }
        }
        return nil
    }

    func postSyntheticClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
            up.post(tap: .cghidEventTap)
        }
    }

    func postSyntheticMouseUpPassthrough(at point: CGPoint, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let up = CGEvent(mouseEventSource: source,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: point,
                               mouseButton: .left) else { return }
        up.flags = flags
        up.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticReleasePassthroughUserData)
        up.post(tap: .cghidEventTap)
    }

    func postSyntheticScroll(at point: CGPoint, deltaY: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.flags = []
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        ev.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
        ev.post(tap: .cghidEventTap)
    }

    private func recordTapEvent(_ type: CGEventType) {
        guard diagnosticsCaptureActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tapEventsSeen += 1
            lastTapEventAt = Date()
            lastTapEventType = String(describing: type)
            switch type {
            case .leftMouseDown:
                tapClicksSeen += 1
            case .scrollWheel:
                tapScrollsSeen += 1
            default:
                break
            }
        }
    }

    func runDiagnosticsCapture(seconds: TimeInterval = 5.0) {
        tapEventsSeen = 0
        tapClicksSeen = 0
        tapScrollsSeen = 0
        lastTapEventAt = nil
        lastTapEventType = nil
        lastDockBundleHit = nil
        lastDockBundleHitAt = nil
        diagnosticsCaptureActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.diagnosticsCaptureActive = false
        }
    }

    func restart() {
        stop()
        refreshPermissionsAndSecurityState()

        if accessibilityGranted && inputMonitoringGranted {
            startIfPossible()
        } else {
            if !accessibilityGranted {
                requestAccessibilityPermission()
            }
            if !inputMonitoringGranted {
                requestInputMonitoringPermission()
            }
            startWhenPermissionAvailable()
        }
        Logger.log("Restart requested. Accessibility granted: \(accessibilityGranted)")
    }

    func toggle() {
        if isEnabled {
            stop()
        } else {
            refreshPermissionsAndSecurityState()

            if !accessibilityGranted {
                requestAccessibilityPermission()
            }
            if !inputMonitoringGranted {
                requestInputMonitoringPermission()
            }

            if accessibilityGranted && inputMonitoringGranted {
                startIfPossible()
            } else {
                startWhenPermissionAvailable()
            }
        }
        Logger.log("Toggle invoked. isEnabled now: \(isEnabled)")
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        Logger.log("Requested accessibility permission prompt.")
    }

    func requestInputMonitoringPermission() {
        let granted = CGRequestListenEventAccess()
        refreshPermissionsAndSecurityState()
        Logger.log("Requested input monitoring permission prompt. grantedNow=\(granted), preflight=\(inputMonitoringGranted)")
    }

    func startWhenPermissionAvailable(pollInterval: TimeInterval = 1.5) {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            guard let self else { return }
            let intervalNs = UInt64(max(pollInterval, 0.2) * 1_000_000_000)

            while !Task.isCancelled {
                let trusted = AXIsProcessTrusted()
                let input = CGPreflightListenEventAccess()
                let secureInput = SecureEventInput.isEnabled()

                accessibilityGranted = trusted
                inputMonitoringGranted = input
                secureEventInputEnabled = secureInput

                if trusted && input {
                    permissionPollTask = nil
                    startIfPossible()
                    Logger.log("Accessibility granted detected via polling; started tap.")
                    return
                }

                Logger.log("Permissions still not granted (accessibility=\(trusted), input=\(input)); polling continues.")

                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    return
                }
            }
        }
    }

    private func handleClick(at location: CGPoint, buttonNumber: Int, flags: CGEventFlags, phase: ClickPhase) -> Bool {
        guard buttonNumber == 0 else {
            if phase == .up {
                pendingClickContext = nil
                pendingClickWasDragged = false
                pendingFolderClickContext = nil
                pendingFolderClickWasDragged = false
            }
            Logger.debug("WORKFLOW: Non-primary mouse button \(buttonNumber) - allowing through")
            return false
        }

        switch phase {
        case .down:
            Logger.debug("WORKFLOW: Click down at \(location.x), \(location.y) button \(buttonNumber)")
            if let folderURL = folderURLNearPoint(location) {
                if let deferred = deferredModifierFirstClickContext {
                    executeDeferredModifierFirstClick(deferred, reason: "newDockFolderClick")
                }
                pendingClickContext = nil
                pendingClickWasDragged = false
                let action = configuredFolderAction(for: .click, flags: flags)
                let consumeMouseUp = shouldConsumeFolderMouseUp(for: action)
                pendingFolderClickContext = PendingFolderClickContext(location: location,
                                                                     buttonNumber: buttonNumber,
                                                                     flags: flags,
                                                                     folderURL: folderURL,
                                                                     consumeMouseUp: consumeMouseUp)
                pendingFolderClickWasDragged = false
                if diagnosticsCaptureActive {
                    lastDockBundleHit = "folder:\(folderURL.path)"
                    lastDockBundleHitAt = Date()
                }
                Logger.debug("WORKFLOW: Folder click down path=\(folderURL.path) action=\(action.debugName) modifier=\(modifierCombination(from: flags).rawValue) consumeMouseUp=\(consumeMouseUp)")
                return false
            }

            let nowUptime = ProcessInfo.processInfo.systemUptime
            let hitBundle = bundleIdentifierNearPoint(location)
            guard let clickedBundle = hitBundle else {
                if isAppExposeInteractionActive(frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier()) {
                    Logger.debug("WORKFLOW: Non-Dock click while App Exposé tracking active; clearing tracking state")
                    resetExposeTracking()
                } else if lastTriggeredBundle != nil || currentExposeApp != nil {
                    Logger.debug("WORKFLOW: Non-Dock click while App Exposé tracking active; resetting tracking state")
                    resetExposeTracking()
                }
                pendingClickContext = nil
                pendingClickWasDragged = false
                pendingFolderClickContext = nil
                pendingFolderClickWasDragged = false
                return false
            }

            pendingFolderClickContext = nil
            pendingFolderClickWasDragged = false

            if let staleContext = pendingClickContext {
                let recoveryPoint = DockHitTest.neutralBackgroundPoint(near: staleContext.location)
                    ?? DockHitTest.neutralBackgroundPoint(near: location)
                    ?? location
                if shouldRecoverStalePendingAsFirstClickActivatePassThrough(staleContext,
                                                                            newBundle: clickedBundle,
                                                                            nowUptime: nowUptime) {
                    recordActionExecution(action: .activateApp,
                                          bundle: staleContext.clickedBundle,
                                          source: "firstClickActivatePassThrough")
                    let recoveredAction = configuredAction(for: .click, flags: staleContext.flags)
                    if shouldAssertActivationForRapidSecondClickPromotion(action: recoveredAction) {
                        scheduleDockActivationAssertionIfNeeded(for: staleContext.clickedBundle,
                                                                frontmostBefore: staleContext.frontmostBefore,
                                                                reason: "stalePendingFirstClickRecovery")
                    }
                    Logger.debug("WORKFLOW: Recovered stale pending click as first-click activate pass-through priorClick=\(staleContext.clickSequence) bundle=\(staleContext.clickedBundle)")
                }
                pendingClickContext = nil
                pendingClickWasDragged = false
                clickRecoveryTokenCounter += 1
                postSyntheticMouseUpPassthrough(at: recoveryPoint, flags: [])
                Logger.debug("WORKFLOW: Recovered stale pending Dock click priorClick=\(staleContext.clickSequence) newBundle=\(clickedBundle) recoveryPoint=(\(Int(recoveryPoint.x)),\(Int(recoveryPoint.y)))")
            }

            var followsDeferredModifierFirstClick = false
            if let deferred = deferredModifierFirstClickContext {
                if shouldPromoteDeferredModifierFirstClick(deferred,
                                                           newBundle: clickedBundle,
                                                           flags: flags) {
                    executeDeferredModifierFirstClick(deferred,
                                                      reason: "promoteDoubleClick",
                                                      shouldRecoverDockPressedStateAfterExecution: false)
                    followsDeferredModifierFirstClick = true
                    Logger.debug("WORKFLOW: Promoting deferred modifier first-click to double-click bundle=\(clickedBundle) modifier=\(modifierCombination(from: flags).rawValue)")
                } else {
                    executeDeferredModifierFirstClick(deferred, reason: "newDockClick")
                }
            }

            if diagnosticsCaptureActive {
                lastDockBundleHit = clickedBundle
                lastDockBundleHitAt = Date()
            }

            clickSequenceCounter += 1
            let clickSequence = clickSequenceCounter
            let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier()
            let context = PendingClickContext(clickSequence: clickSequence,
                                              mouseDownUptime: nowUptime,
                                              location: location,
                                              buttonNumber: buttonNumber,
                                              flags: flags,
                                              frontmostBefore: frontmostBefore,
                                              clickedBundle: clickedBundle,
                                              windowCountAtMouseDown: nil,
                                              followsFirstClickActivation: isRecentFirstClickActivatePassThrough(for: clickedBundle),
                                              followsDeferredModifierFirstClick: followsDeferredModifierFirstClick,
                                              consumeClick: false,
                                              forceFirstClickActivateFallback: false)
            let consumeClick = shouldConsumeClick(for: context)
            let forceFirstClickActivateFallback = shouldForceFirstClickActivateFallback(for: context)
            pendingClickContext = PendingClickContext(clickSequence: context.clickSequence,
                                                     mouseDownUptime: context.mouseDownUptime,
                                                     location: context.location,
                                                     buttonNumber: context.buttonNumber,
                                                     flags: context.flags,
                                                     frontmostBefore: context.frontmostBefore,
                                                     clickedBundle: context.clickedBundle,
                                                     windowCountAtMouseDown: context.windowCountAtMouseDown,
                                                     followsFirstClickActivation: context.followsFirstClickActivation,
                                                     followsDeferredModifierFirstClick: context.followsDeferredModifierFirstClick,
                                                     consumeClick: consumeClick,
                                                     forceFirstClickActivateFallback: forceFirstClickActivateFallback)
            if shouldSchedulePendingDockClickWatchdog(for: pendingClickContext!) {
                pendingDockClickWatchdogTokenCounter += 1
                schedulePendingDockClickWatchdog(context: pendingClickContext!,
                                                 watchdogToken: pendingDockClickWatchdogTokenCounter)
            }
            Logger.debug("APP_EXPOSE_TRACE: click=\(clickSequence) phase=down bundle=\(clickedBundle) frontmostBefore=\(frontmostBefore ?? "nil") windowsAtDown=nil modifier=\(modifierCombination(from: flags).rawValue) firstClickBehavior=\(preferences.firstClickBehavior.rawValue) consumePlanned=\(consumeClick) fallbackLatched=\(forceFirstClickActivateFallback)")
            pendingClickWasDragged = false
            let consumeMouseDown = shouldConsumeMouseDown(for: pendingClickContext!)
            if consumeMouseDown {
                consumedFollowUpClickWatchdogTokenCounter += 1
                scheduleConsumedFollowUpClickWatchdog(context: pendingClickContext!,
                                                      watchdogToken: consumedFollowUpClickWatchdogTokenCounter)
                Logger.debug("WORKFLOW: Consuming mouse-down for recent first-click activation follow-up on \(clickedBundle)")
            }
            return consumeMouseDown

        case .dragged:
            if let context = pendingFolderClickContext {
                pendingFolderClickWasDragged = true
                Logger.debug("WORKFLOW: Folder click became drag; suppressing folder action")
                return false
            }
            if pendingClickContext != nil {
                pendingClickWasDragged = true
                Logger.debug("WORKFLOW: Click became drag; suppressing click action and allowing Dock drag behavior")
                return false
            }
            return false

        case .up:
            if let context = pendingFolderClickContext {
                defer {
                    pendingFolderClickContext = nil
                    pendingFolderClickWasDragged = false
                }

                if pendingFolderClickWasDragged {
                    Logger.debug("WORKFLOW: Folder drag completed; allowing Dock drop behavior")
                    return false
                }

                let resolvedFolderAtMouseUp = folderURLNearPoint(location) ?? context.folderURL
                let effectiveContext = PendingFolderClickContext(location: context.location,
                                                                 buttonNumber: context.buttonNumber,
                                                                 flags: context.flags,
                                                                 folderURL: resolvedFolderAtMouseUp,
                                                                 consumeMouseUp: context.consumeMouseUp)
                return executeFolderClickAction(effectiveContext)
            }

            guard let context = pendingClickContext else {
                if isAppExposeInteractionActive(frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier()),
                   let recoveredBundle = bundleIdentifierNearPoint(location) {
                    Logger.debug("WORKFLOW: Recovered App Exposé dock click on mouse-up for \(recoveredBundle)")
                    let recoveredContext = PendingClickContext(clickSequence: 0,
                                                              mouseDownUptime: ProcessInfo.processInfo.systemUptime,
                                                              location: location,
                                                              buttonNumber: buttonNumber,
                                                              flags: flags,
                                                              frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier(),
                                                              clickedBundle: recoveredBundle,
                                                              windowCountAtMouseDown: nil,
                                                              followsFirstClickActivation: isRecentFirstClickActivatePassThrough(for: recoveredBundle),
                                                              followsDeferredModifierFirstClick: false,
                                                              consumeClick: false,
                                                              forceFirstClickActivateFallback: false)
                    let consumeRecovered = executeClickAction(recoveredContext)
                    return consumeRecovered
                }
                return false
            }

            consumedFollowUpClickWatchdogTokenCounter += 1

            defer {
                pendingClickContext = nil
                pendingClickWasDragged = false
            }

            if pendingClickWasDragged {
                Logger.debug("WORKFLOW: Drag completed; allowing Dock drop behavior")
                return false
            }

            let resolvedBundleAtMouseUp = bundleIdentifierNearPoint(location) ?? context.clickedBundle
            let effectiveContext: PendingClickContext
            if resolvedBundleAtMouseUp != context.clickedBundle {
                Logger.debug("WORKFLOW: Bundle corrected on mouse-up from \(context.clickedBundle) to \(resolvedBundleAtMouseUp)")
                effectiveContext = PendingClickContext(clickSequence: context.clickSequence,
                                                       mouseDownUptime: context.mouseDownUptime,
                                                       location: context.location,
                                                       buttonNumber: context.buttonNumber,
                                                       flags: context.flags,
                                                       frontmostBefore: context.frontmostBefore,
                                                       clickedBundle: resolvedBundleAtMouseUp,
                                                       windowCountAtMouseDown: context.windowCountAtMouseDown,
                                                       followsFirstClickActivation: context.followsFirstClickActivation,
                                                       followsDeferredModifierFirstClick: context.followsDeferredModifierFirstClick,
                                                       consumeClick: context.consumeClick,
                                                       forceFirstClickActivateFallback: context.forceFirstClickActivateFallback)
            } else {
                effectiveContext = context
            }

            Logger.debug("APP_EXPOSE_TRACE: click=\(effectiveContext.clickSequence) phase=up bundle=\(effectiveContext.clickedBundle) frontmostBefore=\(effectiveContext.frontmostBefore ?? "nil") windowsAtDown=\(effectiveContext.windowCountAtMouseDown.map(String.init) ?? "nil") consumePlanned=\(effectiveContext.consumeClick) fallbackLatched=\(effectiveContext.forceFirstClickActivateFallback)")
            let consumeNow = executeClickAction(effectiveContext)
            if consumeNow != context.consumeClick {
                Logger.debug("WORKFLOW: Click consume mismatch click=\(context.clickSequence) planned=\(context.consumeClick) actual=\(consumeNow)")
            }
            // Only recover Dock pressed state when we actually consumed the click-up.
            // If execution resolved to pass-through, synthetic release can interfere with Dock state.
            let shouldRecoverDockPressedState = consumeNow
                && shouldRecoverDockPressedState(after: lastActionExecuted,
                                                 bundleIdentifier: effectiveContext.clickedBundle)
            if shouldRecoverDockPressedState {
                clickRecoveryTokenCounter += 1
                let recoveryToken = clickRecoveryTokenCounter
                scheduleDockPressedStateRecovery(at: context.location,
                                                expectedBundle: context.clickedBundle,
                                                clickToken: recoveryToken,
                                                action: lastActionExecuted)
            }
            return consumeNow
        }
    }

    private func shouldRecoverDockPressedState(after action: DockAction?,
                                               bundleIdentifier: String) -> Bool {
        guard let action else { return false }
        if action == .hideApp, isRecentFirstClickActivatePassThrough(for: bundleIdentifier) {
            return true
        }
        return DockDecisionEngine.shouldRecoverDockPressedState(after: decisionAction(from: action))
    }

    private func shouldConsumeMouseDown(for context: PendingClickContext) -> Bool {
        guard context.consumeClick else { return false }
        guard modifierCombination(from: context.flags) == .none else { return false }
        guard preferences.firstClickBehavior == .activateApp else { return false }
        if context.followsFirstClickActivation {
            return true
        }

        let action = configuredAction(for: .click, flags: context.flags)
        switch action {
        case .hideApp, .quitApp:
            return isRecentActivateAppExecution(for: context.clickedBundle)
        default:
            return false
        }
    }

    private func shouldRecoverStalePendingAsFirstClickActivatePassThrough(_ context: PendingClickContext,
                                                                          newBundle: String,
                                                                          nowUptime: TimeInterval) -> Bool {
        guard context.clickedBundle == newBundle else { return false }
        guard context.frontmostBefore != context.clickedBundle else { return false }
        guard !context.consumeClick else { return false }
        guard modifierCombination(from: context.flags) == .none else { return false }
        guard preferences.firstClickBehavior == .activateApp else { return false }
        guard configuredAction(for: .click, flags: context.flags) != .none else { return false }

        let activationRecoveryWindow = max(NSEvent.doubleClickInterval * 2, 1.25)
        guard nowUptime - context.mouseDownUptime <= activationRecoveryWindow else { return false }
        return true
    }

    private func scheduleDockPressedStateRecovery(at location: CGPoint,
                                                  expectedBundle: String,
                                                  clickToken: UInt64,
                                                  action: DockAction?) {
        var recoveryDelays: [TimeInterval] = [0.008]
        if action == .appExpose {
            // App Exposé consumes the click-up, so the Dock can keep the icon visually pressed.
            // Wait until the Exposé transition has settled, then release over Dock background only.
            // A later second pulse overlaps the next real click cycle and can reintroduce hangs.
            recoveryDelays = [0.35]
        }
        if action == .minimizeAll {
            // Minimize can reshuffle Dock state quickly; a second release pulse avoids
            // occasional long-press/context-menu fallthrough when the first release races.
            recoveryDelays.append(0.12)
        }

        for (index, delay) in recoveryDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard clickToken == self.clickRecoveryTokenCounter else {
                    Logger.debug("WORKFLOW: Skipping stale mouse-up recovery token=\(clickToken) latest=\(self.clickRecoveryTokenCounter)")
                    return
                }
                guard let releasePoint = self.recoveryMouseUpPoint(from: location,
                                                                   expectedBundle: expectedBundle,
                                                                   action: action) else {
                    Logger.debug("WORKFLOW: Skipping mouse-up recovery token=\(clickToken) bundle=\(expectedBundle) reason=noSafeRecoveryPoint")
                    return
                }
                postSyntheticMouseUpPassthrough(at: releasePoint, flags: [])
                Logger.debug("WORKFLOW: Posted neutral mouse-up recovery token=\(clickToken) attempt=\(index + 1)/\(recoveryDelays.count) delayMs=\(Int(delay * 1000)) bundle=\(expectedBundle) point=(\(Int(releasePoint.x)),\(Int(releasePoint.y)))")
            }
        }
    }

    private func recoveryMouseUpPoint(from location: CGPoint,
                                      expectedBundle: String,
                                      action: DockAction?) -> CGPoint? {
        if action == .appExpose {
            if let current = CGEvent(source: nil)?.location,
               case .appDockIcon(let currentBundle) = DockHitTest.pointKind(at: current),
               currentBundle == expectedBundle {
                return current
            }
            if case .appDockIcon(let originalBundle) = DockHitTest.pointKind(at: location),
               originalBundle == expectedBundle {
                return location
            }
            if let current = CGEvent(source: nil)?.location,
               DockHitTest.pointKind(at: current) == .dockBackground {
                return current
            }
            return DockHitTest.neutralBackgroundPoint(near: location)
        }

        // If the pointer is already on a safe Dock target, reuse it to avoid visible jumps.
        if let current = CGEvent(source: nil)?.location {
            switch DockHitTest.pointKind(at: current) {
            case .dockBackground:
                return current
            case .appDockIcon(let bundle):
                if action != .appExpose, action != .minimizeAll, bundle == expectedBundle {
                    return current
                }
            case .folderDockItem:
                break
            case .outsideDock:
                break
            }
        }

        // Otherwise find a nearby Dock background point so Dock receives the release without
        // re-clicking the icon itself.
        if let neutralPoint = DockHitTest.neutralBackgroundPoint(near: location) {
            return neutralPoint
        }

        return location
    }

    private func executeClickAction(_ context: PendingClickContext) -> Bool {
        let location = context.location
        let buttonNumber = context.buttonNumber
        let flags = context.flags
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle
        let appExposeActive = isAppExposeInteractionActive(frontmostBefore: frontmostBefore)
        let recentFirstClickActivation = context.followsFirstClickActivation
            || isRecentFirstClickActivatePassThrough(for: clickedBundle)
        let clickedAppIsActive = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == clickedBundle && $0.isActive
        }

        Logger.debug("WORKFLOW: click=\(context.clickSequence) frontmost=\(frontmostBefore ?? "nil"), clicked=\(clickedBundle), clickedIsActive=\(clickedAppIsActive), windowsDown=\(context.windowCountAtMouseDown.map(String.init) ?? "nil"), fallbackLatched=\(context.forceFirstClickActivateFallback), lastTriggered=\(lastTriggeredBundle ?? "nil"), currentExpose=\(currentExposeApp ?? "nil")")

        if let promotedAction = rapidSecondClickPromotionAction(bundleIdentifier: clickedBundle,
                                                                flags: flags,
                                                                frontmostBefore: frontmostBefore,
                                                                windowCountHint: context.windowCountAtMouseDown) {
            Logger.debug("WORKFLOW: promoting rapid second click to active-click action \(promotedAction.rawValue) for \(clickedBundle)")
            recordActionExecution(action: promotedAction,
                                  bundle: clickedBundle,
                                  source: "rapidSecondClickPromote")
            if shouldAssertActivationForRapidSecondClickPromotion(action: promotedAction) {
                scheduleDockActivationAssertionIfNeeded(for: clickedBundle,
                                                        frontmostBefore: frontmostBefore,
                                                        reason: "rapidSecondClickPromote")
            }
            if promotedAction == .appExpose {
                scheduleDeferredAppExposeTrigger(for: clickedBundle,
                                                 source: "activeClickRapidReclick",
                                                 origin: location)
                return false
            }

            scheduleDeferredRapidSecondClickAction(for: clickedBundle,
                                                   action: promotedAction,
                                                   frontmostBefore: frontmostBefore,
                                                   source: "activeClickRapidReclick")
            return true
        }

        if appExposeActive {
            if currentExposeApp == clickedBundle {
                // Guard against ultra-fast follow-up clicks immediately after opening App Exposé.
                // Without a tiny grace window, an accidental rapid double-click can instantly dismiss it.
                if isRecentExposeInteraction(maxAge: appExposeDismissGraceWindow) {
                    Logger.debug("WORKFLOW: App Exposé dismiss ignored during grace window for \(clickedBundle)")
                    return false
                }

                // User clicked the same app whose windows are in App Exposé – the Dock should dismiss
                // App Exposé and focus the app. Reset tracking now so the next click is handled as a
                // regular active-app click, and assert activation in case Dock focus handoff races.
                Logger.debug("WORKFLOW: App Exposé active - user clicked current app icon; resetting tracking")
                resetExposeTracking()
                scheduleDockActivationAssertionIfNeeded(for: clickedBundle,
                                                        frontmostBefore: frontmostBefore,
                                                        reason: "clickExposeCurrentAppDismiss")
                let bundleToActivate = clickedBundle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleToActivate)
                }
                recordActionExecution(action: .activateApp, bundle: clickedBundle, source: "clickExposeCurrentApp")
                return false
            }
            if currentExposeApp != clickedBundle || lastTriggeredBundle != clickedBundle {
                Logger.debug("WORKFLOW: App Exposé active - tracking switch target \(clickedBundle)")
                currentExposeApp = clickedBundle
                lastTriggeredBundle = clickedBundle
                appsWithoutWindowsInExpose.remove(clickedBundle)
            }
            lastExposeDockClickBundle = clickedBundle
            lastExposeInteractionAt = Date()
            Logger.debug("WORKFLOW: App Exposé active - standing down and allowing macOS Dock behavior")
            return false
        }

        if let currentApp = currentExposeApp,
           currentApp == clickedBundle,
           lastTriggeredBundle != nil,
           lastExposeDockClickBundle == clickedBundle,
           frontmostBefore != clickedBundle {
            if !isRecentExposeInteraction(maxAge: 1.0) {
                Logger.debug("WORKFLOW: Clearing stale App Exposé tracking before deactivate/activate transition for \(clickedBundle)")
                resetExposeTracking()
                return executeFirstClickAction(for: clickedBundle,
                                               at: location,
                                               flags: flags,
                                               frontmostBefore: frontmostBefore,
                                               windowCountHint: context.windowCountAtMouseDown,
                                               forceActivateFallback: context.forceFirstClickActivateFallback)
            }

            if appsWithoutWindowsInExpose.contains(clickedBundle) {
                Logger.debug("WORKFLOW: Second click on app without windows (\(clickedBundle)) - activating and showing main window")
                appsWithoutWindowsInExpose.remove(clickedBundle)
                resetExposeTracking()
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
                recordActionExecution(action: .activateApp, bundle: clickedBundle, source: "clickTransitionActivate")
                return true
            }

            Logger.debug("WORKFLOW: Deactivate click on currentExposeApp (\(clickedBundle)); exiting App Exposé and activating app")
            exitAppExpose()
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
            recordActionExecution(action: .activateApp, bundle: clickedBundle, source: "clickTransitionDeactivate")
            return true
        }

        if frontmostBefore != clickedBundle
            && !clickedAppIsActive
            && !context.followsDeferredModifierFirstClick {
            if lastTriggeredBundle != nil, appExposeActive {
                Logger.debug("WORKFLOW: App Exposé active - user clicked different app (\(clickedBundle)) to show its windows")

                if !WindowManager.hasVisibleWindows(bundleIdentifier: clickedBundle) {
                    Logger.debug("WORKFLOW: App \(clickedBundle) has no visible windows - allowing Dock activation fallback")
                    appsWithoutWindowsInExpose.remove(clickedBundle)
                    resetExposeTracking()
                    scheduleDockActivationAssertionIfNeeded(for: clickedBundle,
                                                            frontmostBefore: frontmostBefore,
                                                            reason: "transitionNoVisibleWindows")
                    recordActionExecution(action: .activateApp,
                                          bundle: clickedBundle,
                                          source: "clickTransitionActivateNoVisibleWindowsPassThrough")
                    return false
                } else {
                    appsWithoutWindowsInExpose.remove(clickedBundle)
                }
                lastTriggeredBundle = clickedBundle
                currentExposeApp = clickedBundle
                lastExposeDockClickBundle = clickedBundle
                lastExposeInteractionAt = Date()
                Logger.debug("WORKFLOW: Updated App Exposé tracking current=\(clickedBundle) last=\(clickedBundle)")
                return false
            } else {
                if lastTriggeredBundle != nil || currentExposeApp != nil {
                    Logger.debug("WORKFLOW: Clearing stale App Exposé tracking before first-click evaluation")
                    resetExposeTracking()
                }
                Logger.debug("WORKFLOW: Different app clicked; evaluating first-click behavior")
                return executeFirstClickAction(for: clickedBundle,
                                               at: location,
                                               flags: flags,
                                               frontmostBefore: frontmostBefore,
                                               windowCountHint: context.windowCountAtMouseDown,
                                               forceActivateFallback: context.forceFirstClickActivateFallback)
            }
        }

        if let lastBundle = lastTriggeredBundle, lastBundle == clickedBundle {
            if frontmostBefore == clickedBundle {
                Logger.debug("WORKFLOW: App Exposé close/dismiss path for \(clickedBundle); forcing cleanup")
                exitAppExpose()
                // This click is part of closing an App Exposé cycle (or stale-tracking cleanup).
                // Never immediately re-trigger App Exposé on the same click.
                recordActionExecution(action: .none,
                                      bundle: clickedBundle,
                                      source: "clickExposeDismissPassThrough")
                return false
            } else {
                Logger.debug("WORKFLOW: Deactivate click on original trigger app (\(clickedBundle)), staying on this app")
                resetExposeTracking()
                recordActionExecution(action: .none, bundle: clickedBundle, source: "clickPassThroughDeactivate")
                return false
            }
        }

        if shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: clickedBundle,
                                                           flags: flags,
                                                           frontmostBefore: frontmostBefore) {
            Logger.debug("WORKFLOW: Promoting immediate post-dismiss click to first-click behavior for \(clickedBundle)")
            return executeFirstClickAction(for: clickedBundle,
                                           at: location,
                                           flags: flags,
                                           frontmostBefore: frontmostBefore,
                                           windowCountHint: context.windowCountAtMouseDown,
                                           forceActivateFallback: context.forceFirstClickActivateFallback)
        }

        let action = configuredAction(for: .click, flags: flags)
        lastActionExecuted = action
        lastActionExecutedBundle = clickedBundle
        lastActionExecutedSource = "click"
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing click action (button \(buttonNumber)) at \(location.x), \(location.y): \(action.rawValue) for \(clickedBundle) (modifiers=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: clickedBundle)
        case .hideApp:
            if recentFirstClickActivation {
                scheduleDeferredRapidSecondClickAction(for: clickedBundle,
                                                       action: .hideApp,
                                                       frontmostBefore: frontmostBefore,
                                                       source: "activeClickRecentActivation")
                return true
            }
            return performHideAppToggle(targetBundleIdentifier: clickedBundle)
        case .hideOthers:
            return performHideOthersToggle(targetBundleIdentifier: clickedBundle,
                                           allowUndoToggle: !recentFirstClickActivation)
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: clickedBundle)
            resetExposeTracking()
            return true
        case .appExpose:
            let windowCountNow = WindowManager.totalWindowCount(bundleIdentifier: clickedBundle)
            if windowCountNow == 0 {
                if shouldSuppressImmediateNoWindowAppExposeClick(for: clickedBundle) {
                    Logger.debug("APP_EXPOSE_DECISION: click appExpose suppression active for \(clickedBundle) during activation grace (windowsNow=0); passing through")
                    return false
                }
                Logger.debug("APP_EXPOSE_DECISION: click appExpose skipped for \(clickedBundle) because windowsNow=0")
                // Let Dock handle the click (e.g. create/show a window) without immediately opening App Exposé.
                return false
            }
            let clickModifier = modifierCombination(from: flags)
            let clickSlot = appExposeSlotKey(for: .click, modifier: clickModifier)
            let clickRequiresMultiple = clickModifier == .none
                ? preferences.clickAppExposeRequiresMultipleWindows
                : preferences.appExposeMultipleWindowsRequired(slot: clickSlot)
            if clickRequiresMultiple, windowCountNow < 2 {
                Logger.debug("APP_EXPOSE_DECISION: click appExpose skipped for \(clickedBundle): fewer than two windows")
                return false
            }
            if shouldUseDeferredDockLifecycleForActiveAppExpose(bundleIdentifier: clickedBundle,
                                                                flags: flags,
                                                                frontmostBefore: frontmostBefore) {
                Logger.debug("WORKFLOW: App Exposé trigger from click using deferred Dock pass-through path")
                scheduleDeferredAppExposeTrigger(for: clickedBundle,
                                                source: "activeClick",
                                                origin: location)
                return false
            }
            Logger.debug("WORKFLOW: App Exposé trigger from click")
            triggerAppExpose(for: clickedBundle)
            return false
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: clickedBundle,
                                 frontmostBefore: frontmostBefore,
                                 allowTargetToggleOff: false,
                                 preferHideOthersBaseline: recentFirstClickActivation)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: clickedBundle) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(clickedBundle); ignoring click")
                return true
            }
            markMinimize(bundleIdentifier: clickedBundle)
            performMinimizeToggle(bundleIdentifier: clickedBundle)
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: clickedBundle)
            return true
        @unknown default:
            return false
        }
    }

    private func recordActionExecution(action: DockAction, bundle: String, source: String) {
        lastActionExecuted = action
        lastActionExecutedBundle = bundle
        lastActionExecutedSource = source
        lastActionExecutedAt = Date()
    }

    private func handleScroll(at location: CGPoint, direction: ScrollDirection, flags: CGEventFlags) -> Bool {
        Logger.debug("WORKFLOW: Scroll \(direction == .up ? "up" : "down") received at \(location.x), \(location.y)")
        guard let target = dockTargetNearPoint(location) else {
            return false
        }

        switch target {
        case .folderDockItem(let folderURL):
            return handleFolderScroll(at: location, folderURL: folderURL, direction: direction, flags: flags)
        case .appDockIcon(let clickedBundle):
            return handleAppScroll(at: location, clickedBundle: clickedBundle, direction: direction, flags: flags)
        case .dockBackground, .outsideDock:
            return false
        }
    }

    private func handleFolderScroll(at location: CGPoint,
                                    folderURL: URL,
                                    direction: ScrollDirection,
                                    flags: CGEventFlags) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        let source: ActionSource = direction == .up ? .scrollUp : .scrollDown
        let action = configuredFolderAction(for: source, flags: flags)
        let targetKey = "folder:\(folderURL.path)"

        if diagnosticsCaptureActive {
            lastDockBundleHit = targetKey
            lastDockBundleHitAt = Date()
        }

        let debounceWindow: TimeInterval = 0.35
        if let lastTime = lastScrollTime,
           let lastBundle = lastScrollBundle,
           let lastDir = lastScrollDirection,
           lastBundle == targetKey,
           lastDir == direction,
           now - lastTime < debounceWindow {
            Logger.debug("WORKFLOW: Folder scroll debounced for \(folderURL.path) direction \(direction == .up ? "up" : "down") (Δ \(now - lastTime))")
            return action != .none
        }

        lastScrollTime = now
        lastScrollBundle = targetKey
        lastScrollDirection = direction

        Logger.log("WORKFLOW: Executing folder scroll \(direction == .up ? "up" : "down") action: \(action.debugName) for \(folderURL.path) (modifiers=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue))")
        return DockFolderActionExecutor.perform(action, folderURL: folderURL)
    }

    private func handleAppScroll(at location: CGPoint,
                                 clickedBundle: String,
                                 direction: ScrollDirection,
                                 flags: CGEventFlags) -> Bool {

        let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier()

        if diagnosticsCaptureActive {
            lastDockBundleHit = clickedBundle
            lastDockBundleHitAt = Date()
        }
        
        let now = Date().timeIntervalSinceReferenceDate
        let debounceWindow: TimeInterval = 0.35
        if let lastTime = lastScrollTime,
           let lastBundle = lastScrollBundle,
           let lastDir = lastScrollDirection,
           lastBundle == clickedBundle,
           lastDir == direction,
           now - lastTime < debounceWindow {
            Logger.debug("WORKFLOW: Scroll debounced for \(clickedBundle) direction \(direction == .up ? "up" : "down") (Δ \(now - lastTime))")
            return true
        }
        lastScrollTime = now
        lastScrollBundle = clickedBundle
        lastScrollDirection = direction

        if isAppExposeInteractionActive(frontmostBefore: frontmostBefore) {
            Logger.debug("WORKFLOW: App Exposé active - ignoring scroll action and allowing system behavior")
            return false
        }

        let source: ActionSource = direction == .up ? .scrollUp : .scrollDown
        let action = configuredAction(for: source, flags: flags)
        lastActionExecuted = action
        lastActionExecutedBundle = clickedBundle
        lastActionExecutedSource = source.rawValue
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing scroll \(direction == .up ? "up" : "down") action: \(action.rawValue) for \(clickedBundle) (modifiers=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: clickedBundle)
        case .hideApp:
            if shouldThrottleScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now) {
                Logger.debug("WORKFLOW: Scroll toggle throttle active for \(clickedBundle) action=\(action.rawValue)")
                return true
            }
            markScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now)
            return performHideAppToggle(targetBundleIdentifier: clickedBundle)
        case .hideOthers:
            if shouldThrottleScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now) {
                Logger.debug("WORKFLOW: Scroll toggle throttle active for \(clickedBundle) action=\(action.rawValue)")
                return true
            }
            markScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now)
            return performHideOthersToggle(targetBundleIdentifier: clickedBundle)
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: clickedBundle)
            resetExposeTracking()
            return true
        case .appExpose:
            let scrollModifier = modifierCombination(from: flags)
            let scrollSlot = appExposeSlotKey(for: source, modifier: scrollModifier)
            let scrollRequiresMultiple = preferences.appExposeMultipleWindowsRequired(slot: scrollSlot)
            if scrollRequiresMultiple {
                let windowCountNow = WindowManager.totalWindowCount(bundleIdentifier: clickedBundle)
                if windowCountNow < 2 {
                    Logger.debug("APP_EXPOSE_DECISION: scroll appExpose skipped for \(clickedBundle): fewer than two windows")
                    return false
                }
            }
            triggerAppExpose(for: clickedBundle)
            // Keep scroll pass-through for App Exposé trigger path.
            return false
        case .singleAppMode:
            if shouldThrottleScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now) {
                Logger.debug("WORKFLOW: Scroll toggle throttle active for \(clickedBundle) action=\(action.rawValue)")
                return true
            }
            markScrollToggle(action: action, bundleIdentifier: clickedBundle, now: now)
            performSingleAppMode(targetBundleIdentifier: clickedBundle, frontmostBefore: frontmostBefore)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: clickedBundle) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(clickedBundle); ignoring scroll")
                return true
            }
            markMinimize(bundleIdentifier: clickedBundle)
            performMinimizeToggle(bundleIdentifier: clickedBundle)
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: clickedBundle)
            return true
        @unknown default:
            return false
        }
    }

    private enum ActionSource: String {
        case click
        case scrollUp
        case scrollDown
    }

    private enum ModifierCombination: String {
        case none
        case shift
        case option
        case shiftOption
    }

    private func modifierCombination(from flags: CGEventFlags) -> ModifierCombination {
        let hasShift = flags.contains(.maskShift)
        let hasOption = flags.contains(.maskAlternate)
        switch (hasShift, hasOption) {
        case (true, true):
            return .shiftOption
        case (true, false):
            return .shift
        case (false, true):
            return .option
        case (false, false):
            return .none
        }
    }

    private func appExposeSlotKey(for source: ActionSource, modifier: ModifierCombination) -> String {
        AppExposeSlotKey.make(source: source.rawValue, modifier: modifier.rawValue)
    }

    private func firstClickSlotKey(for modifier: ModifierCombination) -> String {
        AppExposeSlotKey.make(source: AppExposeSlotSource.firstClick.rawValue, modifier: modifier.rawValue)
    }

    private func configuredAction(for source: ActionSource, flags: CGEventFlags) -> DockAction {
        switch source {
        case .click:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.clickAction
            case .shift:
                return preferences.shiftClickAction
            case .option:
                return preferences.optionClickAction
            case .shiftOption:
                return preferences.shiftOptionClickAction
            }
        case .scrollUp:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.scrollUpAction
            case .shift:
                return preferences.shiftScrollUpAction
            case .option:
                return preferences.optionScrollUpAction
            case .shiftOption:
                return preferences.shiftOptionScrollUpAction
            }
        case .scrollDown:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.scrollDownAction
            case .shift:
                return preferences.shiftScrollDownAction
            case .option:
                return preferences.optionScrollDownAction
            case .shiftOption:
                return preferences.shiftOptionScrollDownAction
            }
        }
    }

    private func configuredFolderAction(for source: ActionSource, flags: CGEventFlags) -> DockFolderAction {
        switch source {
        case .click:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.folderClickAction
            case .shift:
                return preferences.shiftFolderClickAction
            case .option:
                return preferences.optionFolderClickAction
            case .shiftOption:
                return preferences.shiftOptionFolderClickAction
            }
        case .scrollUp:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.folderScrollUpAction
            case .shift:
                return preferences.shiftFolderScrollUpAction
            case .option:
                return preferences.optionFolderScrollUpAction
            case .shiftOption:
                return preferences.shiftOptionFolderScrollUpAction
            }
        case .scrollDown:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.folderScrollDownAction
            case .shift:
                return preferences.shiftFolderScrollDownAction
            case .option:
                return preferences.optionFolderScrollDownAction
            case .shiftOption:
                return preferences.shiftOptionFolderScrollDownAction
            }
        }
    }

    private func shouldConsumeFolderMouseUp(for action: DockFolderAction) -> Bool {
        guard action.isConfigured else { return false }
        // Let Dock handle its own stack interactions directly so drag/reorder/drop still work.
        return !action.opensInDock
    }

    private func executeFolderClickAction(_ context: PendingFolderClickContext) -> Bool {
        let action = configuredFolderAction(for: .click, flags: context.flags)
        guard context.consumeMouseUp else {
            Logger.debug("WORKFLOW: Allowing Dock folder click passthrough for \(context.folderURL.path) action=\(action.debugName)")
            return false
        }

        if let releasePoint = DockHitTest.neutralBackgroundPoint(near: context.location) {
            postSyntheticMouseUpPassthrough(at: releasePoint, flags: [])
            Logger.debug("WORKFLOW: Posted neutral folder mouse-up recovery for \(context.folderURL.path) point=(\(Int(releasePoint.x)),\(Int(releasePoint.y)))")
        } else {
            Logger.debug("WORKFLOW: No neutral folder recovery point available for \(context.folderURL.path)")
        }

        Logger.log("WORKFLOW: Executing folder click action: \(action.debugName) for \(context.folderURL.path) (modifiers=\(modifierCombination(from: context.flags).rawValue), flags=\(context.flags.rawValue))")
        return DockFolderActionExecutor.perform(action, folderURL: context.folderURL)
    }

    private func decisionBehavior(from behavior: FirstClickBehavior) -> DecisionFirstClickBehavior {
        switch behavior {
        case .activateApp:
            return .activateApp
        case .bringAllToFront:
            return .bringAllToFront
        case .appExpose:
            return .appExpose
        }
    }

    private func decisionAction(from action: DockAction) -> DecisionDockAction {
        switch action {
        case .none:
            return .none
        case .activateApp:
            return .activateApp
        case .hideApp:
            return .hideApp
        case .appExpose:
            return .appExpose
        case .minimizeAll:
            return .minimizeAll
        case .quitApp:
            return .quitApp
        case .bringAllToFront:
            return .bringAllToFront
        case .hideOthers:
            return .hideOthers
        case .singleAppMode:
            return .singleAppMode
        @unknown default:
            return .none
        }
    }

    private func executeFirstClickBehavior(for bundleIdentifier: String,
                                           frontmostBefore: String?,
                                           windowCountHint: Int? = nil,
                                           forceActivateFallback: Bool = false) -> Bool {
        switch preferences.firstClickBehavior {
        case .activateApp:
            Logger.debug("WORKFLOW: First click behavior=activateApp; allowing Dock activation")
            // Mark pass-through activation so an immediate no-window App Exposé re-click
            // can be suppressed (avoids Dock "boop" while the app is still activating).
            recordActionExecution(action: .activateApp,
                                  bundle: bundleIdentifier,
                                  source: "firstClickActivatePassThrough")
            scheduleDockActivationAssertionIfNeeded(for: bundleIdentifier,
                                                    frontmostBefore: frontmostBefore,
                                                    reason: "firstClickActivatePassThrough")
            return false
        case .bringAllToFront:
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                Logger.debug("WORKFLOW: First click behavior=bringAllToFront but app not running; allowing Dock launch")
                return false
            }
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
            }
            if !WindowManager.bringAllToFront(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
            }
            Logger.debug("WORKFLOW: First click behavior=bringAllToFront executed for \(bundleIdentifier)")
            return true
        case .appExpose:
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                Logger.debug("WORKFLOW: First click behavior=appExpose but app not running; allowing Dock launch")
                return false
            }
            let windowCountNow = windowCountHint ?? WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose bundle=\(bundleIdentifier) forceFallback=\(forceActivateFallback) windowsNow=\(windowCountNow)")
            if forceActivateFallback {
                Logger.debug("APP_EXPOSE_DECISION: firstClick forced fallback for \(bundleIdentifier); allowing Dock activation")
                // Keep Dock's native click lifecycle intact for no-window fallback cases.
                scheduleDockActivationAssertionIfNeeded(for: bundleIdentifier,
                                                        frontmostBefore: frontmostBefore,
                                                        reason: "forcedFallback")
                return false
            }
            if windowCountNow == 0 {
                Logger.debug("APP_EXPOSE_DECISION: firstClick no-window fallback for \(bundleIdentifier); allowing Dock activation")
                // Let Dock handle activation to avoid consumed click-up/recovery edge cases.
                scheduleDockActivationAssertionIfNeeded(for: bundleIdentifier,
                                                        frontmostBefore: frontmostBefore,
                                                        reason: "noWindows")
                return false
            }
            guard shouldRunFirstClickAppExpose(for: bundleIdentifier, windowCountHint: windowCountNow) else {
                Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose skipped by shouldRunFirstClickAppExpose for \(bundleIdentifier)")
                scheduleDockActivationAssertionIfNeeded(for: bundleIdentifier,
                                                        frontmostBefore: frontmostBefore,
                                                        reason: "multipleWindowsGate")
                return false
            }
            lastActionExecuted = .appExpose
            lastActionExecutedBundle = bundleIdentifier
            lastActionExecutedSource = "firstClick"
            lastActionExecutedAt = Date()
            Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose executing for \(bundleIdentifier)")
            scheduleDeferredAppExposeTrigger(for: bundleIdentifier, source: "firstClick")
            // Keep Dock's press/release lifecycle untouched for App Exposé.
            return false
        }
    }

    private func executeFirstClickAction(for bundleIdentifier: String,
                                         at location: CGPoint,
                                         flags: CGEventFlags,
                                         frontmostBefore: String?,
                                         windowCountHint: Int? = nil,
                                         forceActivateFallback: Bool = false) -> Bool {
        let modifier = modifierCombination(from: flags)

        if modifier == .none {
            return executeFirstClickBehavior(for: bundleIdentifier,
                                             frontmostBefore: frontmostBefore,
                                             windowCountHint: windowCountHint,
                                             forceActivateFallback: forceActivateFallback)
        }

        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        if !isRunning {
            Logger.debug("WORKFLOW: First click modifier action requested but app not running; allowing Dock launch")
            return false
        }

        let action: DockAction
        switch modifier {
        case .shift:
            action = preferences.firstClickShiftAction
        case .option:
            action = preferences.firstClickOptionAction
        case .shiftOption:
            action = preferences.firstClickShiftOptionAction
        case .none:
            action = .none
        }

        if action == .appExpose {
            let slot = firstClickSlotKey(for: modifier)
            let requiresMultiple = preferences.appExposeMultipleWindowsRequired(slot: slot)
            if !shouldRunAppExpose(for: bundleIdentifier,
                                   windowCountHint: windowCountHint,
                                   requiresMultipleWindows: requiresMultiple) {
                return false
            }
        }

        if action == .none {
            Logger.debug("WORKFLOW: First click modifier action is none; allowing Dock activation")
            return false
        }

        if shouldDeferModifierFirstClickAction(action: action,
                                               bundleIdentifier: bundleIdentifier,
                                               flags: flags,
                                               frontmostBefore: frontmostBefore) {
            scheduleDeferredModifierFirstClickAction(action: action,
                                                     bundleIdentifier: bundleIdentifier,
                                                     flags: flags,
                                                     frontmostBefore: frontmostBefore,
                                                     location: location)
            Logger.debug("WORKFLOW: Deferring first-click modifier action to preserve double-click bundle=\(bundleIdentifier) modifier=\(modifier.rawValue) action=\(action.rawValue)")
            return true
        }

        return performFirstClickModifierAction(action: action,
                                               bundleIdentifier: bundleIdentifier,
                                               flags: flags,
                                               frontmostBefore: frontmostBefore,
                                               source: "firstClickModifier")
    }

    private func performFirstClickModifierAction(action: DockAction,
                                                 bundleIdentifier: String,
                                                 flags: CGEventFlags,
                                                 frontmostBefore: String?,
                                                 source: String) -> Bool {
        lastActionExecuted = action
        lastActionExecutedBundle = bundleIdentifier
        lastActionExecutedSource = source
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing first-click modifier action: \(action.rawValue) for \(bundleIdentifier) (modifier=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue), source=\(source))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: bundleIdentifier)
        case .hideApp:
            return performHideAppToggle(targetBundleIdentifier: bundleIdentifier)
        case .hideOthers:
            return performHideOthersToggle(targetBundleIdentifier: bundleIdentifier)
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: bundleIdentifier)
            resetExposeTracking()
            return true
        case .appExpose:
            Logger.debug("WORKFLOW: App Exposé trigger from first-click modifier")
            scheduleDeferredAppExposeTrigger(for: bundleIdentifier, source: "firstClickModifier")
            // Keep Dock's click lifecycle untouched for App Exposé.
            return false
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: bundleIdentifier, frontmostBefore: frontmostBefore)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: bundleIdentifier) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(bundleIdentifier); ignoring first-click modifier")
                return true
            }
            markMinimize(bundleIdentifier: bundleIdentifier)
            performMinimizeToggle(bundleIdentifier: bundleIdentifier)
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: bundleIdentifier)
            return true
        @unknown default:
            return false
        }
    }

    private func clearDeferredModifierFirstClickContext() {
        deferredModifierFirstClickContext = nil
    }

    private func shouldDeferModifierFirstClickAction(action: DockAction,
                                                     bundleIdentifier: String,
                                                     flags: CGEventFlags,
                                                     frontmostBefore: String?) -> Bool {
        guard frontmostBefore != bundleIdentifier else { return false }
        guard modifierCombination(from: flags) != .none else { return false }
        guard configuredAction(for: .click, flags: flags) != .none else { return false }
        return DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: decisionAction(from: action),
            isRunning: true,
            canRunAppExpose: true
        )
    }

    private func scheduleDeferredModifierFirstClickAction(action: DockAction,
                                                          bundleIdentifier: String,
                                                          flags: CGEventFlags,
                                                          frontmostBefore: String?,
                                                          location: CGPoint) {
        deferredModifierFirstClickTokenCounter += 1
        let token = deferredModifierFirstClickTokenCounter
        let context = DeferredModifierFirstClickContext(token: token,
                                                        location: location,
                                                        flags: flags,
                                                        frontmostBefore: frontmostBefore,
                                                        clickedBundle: bundleIdentifier,
                                                        action: action,
                                                        queuedAt: Date())
        deferredModifierFirstClickContext = context

        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard let self else { return }
            guard let pending = self.deferredModifierFirstClickContext,
                  pending.token == token else { return }
            self.executeDeferredModifierFirstClick(pending, reason: "timeout")
        }
    }

    private func shouldPromoteDeferredModifierFirstClick(_ context: DeferredModifierFirstClickContext,
                                                         newBundle: String,
                                                         flags: CGEventFlags) -> Bool {
        guard context.clickedBundle == newBundle else { return false }
        guard Date().timeIntervalSince(context.queuedAt) <= NSEvent.doubleClickInterval else { return false }
        guard modifierCombination(from: context.flags) == modifierCombination(from: flags) else { return false }
        guard configuredAction(for: .click, flags: flags) != .none else { return false }
        return true
    }

    private func executeDeferredModifierFirstClick(_ context: DeferredModifierFirstClickContext,
                                                   reason: String,
                                                   shouldRecoverDockPressedStateAfterExecution: Bool = true) {
        guard deferredModifierFirstClickContext?.token == context.token else { return }
        clearDeferredModifierFirstClickContext()
        Logger.debug("WORKFLOW: Executing deferred first-click modifier action reason=\(reason) bundle=\(context.clickedBundle) modifier=\(modifierCombination(from: context.flags).rawValue) action=\(context.action.rawValue)")

        let consumeNow = performFirstClickModifierAction(action: context.action,
                                                         bundleIdentifier: context.clickedBundle,
                                                         flags: context.flags,
                                                         frontmostBefore: context.frontmostBefore,
                                                         source: "firstClickModifierDeferred")
        let shouldRecoverDockPressedStateNow = shouldRecoverDockPressedStateAfterExecution
            && consumeNow
            && shouldRecoverDockPressedState(after: lastActionExecuted,
                                             bundleIdentifier: context.clickedBundle)
        if shouldRecoverDockPressedStateNow {
            clickRecoveryTokenCounter += 1
            let recoveryToken = clickRecoveryTokenCounter
            scheduleDockPressedStateRecovery(at: context.location,
                                             expectedBundle: context.clickedBundle,
                                             clickToken: recoveryToken,
                                             action: lastActionExecuted)
        }
    }

    private func handleEventTapTimeout() {
        clickRecoveryTokenCounter += 1
        activationAssertionTokenCounter += 1
        pendingClickContext = nil
        pendingClickWasDragged = false
        clearDeferredModifierFirstClickContext()
        lastScrollBundle = nil
        lastScrollDirection = nil
        lastScrollTime = nil

        let hadExposeState = appExposeInvocationToken != nil
            || lastTriggeredBundle != nil
            || currentExposeApp != nil
            || lastExposeDockClickBundle != nil

        if hadExposeState {
            Logger.log("WORKFLOW: Event tap timeout recovery: clearing pending click/app Exposé tracking state")
        } else {
            Logger.log("WORKFLOW: Event tap timeout recovery: clearing pending click state")
        }

        resetExposeTracking()
    }

    private func resetExposeTracking() {
        exposeTrackingExpiryTokenCounter += 1
        appExposeInvocationToken = nil
        lastTriggeredBundle = nil
        currentExposeApp = nil
        lastExposeDockClickBundle = nil
        lastExposeInteractionAt = nil
        appsWithoutWindowsInExpose.removeAll()
    }

    private func handleWorkspaceActivation(bundleIdentifier activatedBundle: String) {
        guard appExposeInvocationToken == nil else { return }
        guard lastTriggeredBundle != nil || currentExposeApp != nil else { return }

        let trackedBundle = currentExposeApp ?? lastTriggeredBundle
        if activatedBundle == trackedBundle || activatedBundle == "com.apple.dock" {
            return
        }

        Logger.debug("WORKFLOW: Clearing App Exposé tracking on workspace activation activated=\(activatedBundle) tracked=\(trackedBundle ?? "nil")")
        resetExposeTracking()
    }

    private func completeAppExposeInvocation(token: UUID,
                                             bundleIdentifier: String,
                                             startedAt: Date,
                                             deferredContext: DeferredAppExposeContext?) {
        guard appExposeInvocationToken == token else { return }

        let previousLastTriggeredBundle = lastTriggeredBundle
        let previousCurrentExposeApp = currentExposeApp
        let previousLastExposeDockClickBundle = lastExposeDockClickBundle
        let previousLastExposeInteractionAt = lastExposeInteractionAt
        let previousAppsWithoutWindows = appsWithoutWindowsInExpose

        appExposeInvocationToken = nil

        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let currentFrontmost = FrontmostAppTracker.frontmostBundleIdentifier()
        Logger.debug("WORKFLOW: App Exposé invoke target=\(bundleIdentifier) frontmost=\(currentFrontmost ?? "nil") latencyMs=\(latencyMs)")

        if currentFrontmost != bundleIdentifier {
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        }

        let result = invoker.invokeApplicationWindows(for: bundleIdentifier, requireEvidence: true)
        Logger.debug("WORKFLOW: App Exposé invoke result target=\(bundleIdentifier) dispatched=\(result.dispatched) evidence=\(result.evidence) confirmed=\(result.confirmed) strategy=\(result.strategy?.rawValue ?? "none") frontmostAfter=\(result.frontmostAfter)")

        if DockDecisionEngine.shouldCommitAppExposeTracking(invocationConfirmed: result.confirmed) {
            lastTriggeredBundle = bundleIdentifier
            currentExposeApp = bundleIdentifier
            lastExposeDockClickBundle = bundleIdentifier
            lastExposeInteractionAt = Date()
            appsWithoutWindowsInExpose.remove(bundleIdentifier)
            scheduleExposeTrackingExpiry(for: bundleIdentifier)
            Logger.debug("WORKFLOW: App Exposé tracking commit confirmed for \(bundleIdentifier)")
            return
        }

        let rollbackReason: String
        if result.dispatched && !result.evidence {
            rollbackReason = "unconfirmed invocation (dispatched without evidence)"
        } else if result.dispatched {
            rollbackReason = "unconfirmed invocation"
        } else {
            rollbackReason = "dispatch failed"
        }

        if previousLastTriggeredBundle != nil || previousCurrentExposeApp != nil {
            lastTriggeredBundle = previousLastTriggeredBundle
            currentExposeApp = previousCurrentExposeApp
            lastExposeDockClickBundle = previousLastExposeDockClickBundle
            lastExposeInteractionAt = previousLastExposeInteractionAt
            appsWithoutWindowsInExpose = previousAppsWithoutWindows
            Logger.debug("WORKFLOW: App Exposé tracking rollback target=\(bundleIdentifier) reason=\(rollbackReason) action=restorePrevious")
        } else {
            resetExposeTracking()
            Logger.debug("WORKFLOW: App Exposé tracking rollback target=\(bundleIdentifier) reason=\(rollbackReason) action=reset")
        }
    }

    private func scheduleExposeTrackingExpiry(for bundleIdentifier: String) {
        exposeTrackingExpiryTokenCounter += 1
        let token = exposeTrackingExpiryTokenCounter

        DispatchQueue.main.asyncAfter(deadline: .now() + exposeTrackingExpiryWindow) { [weak self] in
            guard let self else { return }
            guard token == self.exposeTrackingExpiryTokenCounter else { return }
            guard self.appExposeInvocationToken == nil else { return }
            guard self.currentExposeApp == bundleIdentifier || self.lastTriggeredBundle == bundleIdentifier else { return }
            guard self.isRecentExposeInteraction(maxAge: self.exposeTrackingExpiryWindow) else {
                Logger.debug("WORKFLOW: Expiring App Exposé tracking target=\(bundleIdentifier) after inactivity window")
                self.resetExposeTracking()
                return
            }
        }
    }

    private func shouldConsumeClick(for context: PendingClickContext) -> Bool {
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle
        let flags = context.flags
        let appExposeActive = isAppExposeInteractionActive(frontmostBefore: frontmostBefore)

        if appExposeActive {
            return false
        }

        if let promotedAction = rapidSecondClickPromotionAction(bundleIdentifier: clickedBundle,
                                                                flags: flags,
                                                                frontmostBefore: frontmostBefore,
                                                                windowCountHint: context.windowCountAtMouseDown) {
            return DockDecisionEngine.shouldConsumeActiveClickAction(
                action: decisionAction(from: promotedAction),
                canRunAppExpose: true
            )
        }

        let clickedAppIsActive = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == clickedBundle && $0.isActive
        }

        if frontmostBefore != clickedBundle
            && !clickedAppIsActive
            && !context.followsDeferredModifierFirstClick {
            if lastTriggeredBundle != nil, appExposeInvocationToken != nil {
                return false
            }
            return shouldConsumeFirstClickAction(for: clickedBundle,
                                                 flags: flags,
                                                 windowCountHint: context.windowCountAtMouseDown)
        }

        if let lastBundle = lastTriggeredBundle, lastBundle == clickedBundle {
            if frontmostBefore != clickedBundle {
                return false
            }
            let action = configuredAction(for: .click, flags: flags)
            if action == .appExpose {
                return shouldConsumeActiveClickAppExpose(for: clickedBundle,
                                                         flags: flags,
                                                         frontmostBefore: frontmostBefore)
            }
            return DockDecisionEngine.shouldConsumeActiveClickAction(
                action: decisionAction(from: action),
                canRunAppExpose: true
            )
        }

        if shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: clickedBundle,
                                                           flags: flags,
                                                           frontmostBefore: frontmostBefore) {
            return shouldConsumeFirstClickAction(for: clickedBundle, flags: flags)
        }

        let action = configuredAction(for: .click, flags: flags)
        if action == .appExpose {
            return shouldConsumeActiveClickAppExpose(for: clickedBundle,
                                                     flags: flags,
                                                     frontmostBefore: frontmostBefore)
        }
        return DockDecisionEngine.shouldConsumeActiveClickAction(
            action: decisionAction(from: action),
            canRunAppExpose: true
        )
    }

    private func shouldForceFirstClickActivateFallback(for context: PendingClickContext) -> Bool {
        guard context.frontmostBefore != context.clickedBundle else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=alreadyFrontmost")
            return false
        }
        guard modifierCombination(from: context.flags) == .none else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=modifier")
            return false
        }
        guard preferences.firstClickBehavior == .appExpose else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=firstClickBehavior(\(preferences.firstClickBehavior.rawValue))")
            return false
        }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == context.clickedBundle }) else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=notRunning")
            return false
        }
        let windows = context.windowCountAtMouseDown ?? WindowManager.totalWindowCount(bundleIdentifier: context.clickedBundle)
        let shouldLatch = windows == 0
        Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=\(shouldLatch) windowsAtDown=\(windows)")
        return shouldLatch
    }

    private func isAppExposeInteractionActive(frontmostBefore: String?) -> Bool {
        DockDecisionEngine.isAppExposeInteractionActive(
            hasInvocationToken: appExposeInvocationToken != nil,
            frontmostBefore: frontmostBefore,
            hasTrackingState: lastTriggeredBundle != nil || currentExposeApp != nil,
            isRecentInteraction: isRecentExposeInteraction(maxAge: 1.2)
        )
    }

    private func shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: String,
                                                                 flags: CGEventFlags,
                                                                 frontmostBefore: String?) -> Bool {
        guard frontmostBefore == bundleIdentifier else { return false }
        guard configuredAction(for: .click, flags: flags) == .none else { return false }
        guard preferences.firstClickBehavior == .appExpose else { return false }
        guard preferences.firstClickAppExposeRequiresMultipleWindows == false
                || WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) else { return false }
        guard lastActionExecuted == .activateApp,
              lastActionExecutedBundle == bundleIdentifier,
              lastActionExecutedSource == "clickTransitionDeactivate",
              let lastAt = lastActionExecutedAt else { return false }
        return Date().timeIntervalSince(lastAt) <= 1.0
    }

    private func shouldConsumeFirstClickAction(for bundleIdentifier: String,
                                               flags: CGEventFlags,
                                               windowCountHint: Int? = nil) -> Bool {
        let modifier = modifierCombination(from: flags)
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }

        if modifier == .none {
            let windowCount = windowCountHint ?? WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            return DockDecisionEngine.shouldConsumeFirstClickPlainAction(
                firstClickBehavior: decisionBehavior(from: preferences.firstClickBehavior),
                isRunning: isRunning,
                windowCount: windowCount
            )
        }

        guard isRunning else { return false }

        let action: DockAction
        switch modifier {
        case .shift:
            action = preferences.firstClickShiftAction
        case .option:
            action = preferences.firstClickOptionAction
        case .shiftOption:
            action = preferences.firstClickShiftOptionAction
        case .none:
            action = .none
        }

        let canRunAppExpose: Bool
        if action == .appExpose {
            let slot = firstClickSlotKey(for: modifier)
            let requiresMultiple = preferences.appExposeMultipleWindowsRequired(slot: slot)
            canRunAppExpose = shouldRunAppExpose(for: bundleIdentifier,
                                                 windowCountHint: windowCountHint,
                                                 requiresMultipleWindows: requiresMultiple)
            if !canRunAppExpose {
                return false
            }
        } else {
            canRunAppExpose = true
        }

        return DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: decisionAction(from: action),
            isRunning: isRunning,
            canRunAppExpose: canRunAppExpose
        )
    }

    private func shouldRunFirstClickAppExpose(for bundleIdentifier: String,
                                              windowCountHint: Int? = nil) -> Bool {
        shouldRunAppExpose(for: bundleIdentifier,
                           windowCountHint: windowCountHint,
                           requiresMultipleWindows: preferences.firstClickAppExposeRequiresMultipleWindows)
    }

    private func shouldSuppressImmediateNoWindowAppExposeClick(for bundleIdentifier: String) -> Bool {
        isRecentFirstClickActivatePassThrough(for: bundleIdentifier)
    }

    private func isRecentFirstClickActivatePassThrough(for bundleIdentifier: String) -> Bool {
        guard lastActionExecuted == .activateApp,
              lastActionExecutedBundle == bundleIdentifier,
              lastActionExecutedSource == "firstClickActivatePassThrough",
              let lastAt = lastActionExecutedAt else {
            return false
        }
        // Match macOS' user-configured double-click interval so this grace window
        // feels consistent with system click timing preferences.
        return Date().timeIntervalSince(lastAt) <= NSEvent.doubleClickInterval
    }

    private func isRecentActivateAppExecution(for bundleIdentifier: String,
                                              maxAge: TimeInterval = max(NSEvent.doubleClickInterval * 2, 1.25)) -> Bool {
        guard lastActionExecuted == .activateApp,
              lastActionExecutedBundle == bundleIdentifier,
              let lastAt = lastActionExecutedAt else {
            return false
        }
        return Date().timeIntervalSince(lastAt) <= maxAge
    }

    private func rapidSecondClickPromotionAction(bundleIdentifier: String,
                                                 flags: CGEventFlags,
                                                 frontmostBefore: String?,
                                                 windowCountHint: Int?) -> DockAction? {
        guard modifierCombination(from: flags) == .none else { return nil }
        guard frontmostBefore != bundleIdentifier else { return nil }
        guard preferences.firstClickBehavior == .activateApp else { return nil }
        guard isRecentFirstClickActivatePassThrough(for: bundleIdentifier) else { return nil }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }

        let action = configuredAction(for: .click, flags: flags)
        switch action {
        case .none, .activateApp:
            return nil
        case .appExpose:
            let windowCount = windowCountHint ?? WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            guard windowCount > 0 else { return nil }
            if preferences.clickAppExposeRequiresMultipleWindows && windowCount < 2 {
                return nil
            }
            return .appExpose
        default:
            return action
        }
    }

    private func scheduleDeferredRapidSecondClickAction(for bundleIdentifier: String,
                                                        action: DockAction,
                                                        frontmostBefore: String?,
                                                        source: String,
                                                        remainingAttempts: Int = 7) {
        let delay: TimeInterval = remainingAttempts == 7 ? 0.02 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if action == .hideApp {
                Logger.debug("WORKFLOW: Deferred rapid active-click action source=\(source) action=\(action.rawValue) target=\(bundleIdentifier) without frontmost wait")
                self.executeDeferredRapidSecondClickAction(action: action,
                                                           bundleIdentifier: bundleIdentifier,
                                                           frontmostBefore: frontmostBefore)
                return
            }

            let frontmost = FrontmostAppTracker.frontmostBundleIdentifier()
            if frontmost != bundleIdentifier {
                guard remainingAttempts > 0 else {
                    Logger.debug("WORKFLOW: Deferred rapid active-click action abandoned source=\(source) action=\(action.rawValue) target=\(bundleIdentifier) frontmost=\(frontmost ?? "nil")")
                    return
                }

                Logger.debug("WORKFLOW: Waiting for deferred rapid active-click action source=\(source) action=\(action.rawValue) target=\(bundleIdentifier) frontmost=\(frontmost ?? "nil") remainingAttempts=\(remainingAttempts)")
                self.scheduleDeferredRapidSecondClickAction(for: bundleIdentifier,
                                                            action: action,
                                                            frontmostBefore: frontmostBefore,
                                                            source: source,
                                                            remainingAttempts: remainingAttempts - 1)
                return
            }

            Logger.debug("WORKFLOW: Deferred rapid active-click action source=\(source) action=\(action.rawValue) target=\(bundleIdentifier)")
            self.executeDeferredRapidSecondClickAction(action: action,
                                                       bundleIdentifier: bundleIdentifier,
                                                       frontmostBefore: frontmostBefore)
        }
    }

    private func shouldAssertActivationForRapidSecondClickPromotion(action: DockAction) -> Bool {
        switch action {
        case .hideApp, .quitApp:
            return false
        default:
            return true
        }
    }

    private func executeDeferredRapidSecondClickAction(action: DockAction,
                                                       bundleIdentifier: String,
                                                       frontmostBefore: String?) {
        switch action {
        case .none:
            return
        case .activateApp:
            _ = performActivateAppAction(bundleIdentifier: bundleIdentifier)
        case .hideApp:
            _ = performHideAppToggle(targetBundleIdentifier: bundleIdentifier)
        case .hideOthers:
            _ = performHideOthersToggle(targetBundleIdentifier: bundleIdentifier,
                                        allowUndoToggle: false)
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: bundleIdentifier)
            resetExposeTracking()
        case .appExpose:
            scheduleDeferredAppExposeTrigger(for: bundleIdentifier,
                                             source: "activeClickRapidReclickDeferred")
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: bundleIdentifier,
                                 frontmostBefore: frontmostBefore,
                                 allowTargetToggleOff: false,
                                 preferHideOthersBaseline: true)
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: bundleIdentifier) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(bundleIdentifier); ignoring deferred rapid click")
                return
            }
            markMinimize(bundleIdentifier: bundleIdentifier)
            performMinimizeToggle(bundleIdentifier: bundleIdentifier)
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: bundleIdentifier)
        @unknown default:
            return
        }
    }

    private func shouldRunAppExpose(for bundleIdentifier: String,
                                    windowCountHint: Int? = nil,
                                    requiresMultipleWindows: Bool) -> Bool {
        let windowCount = windowCountHint ?? WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
        let shouldRun = DockDecisionEngine.shouldRunFirstClickAppExpose(
            windowCount: windowCount,
            requiresMultipleWindows: requiresMultipleWindows
        )
        if !shouldRun {
            if windowCount == 0 {
                Logger.debug("WORKFLOW: appExpose skipped for \(bundleIdentifier): no windows")
            } else if requiresMultipleWindows && windowCount < 2 {
                Logger.debug("WORKFLOW: appExpose skipped for \(bundleIdentifier): fewer than two windows")
            }
        }
        return shouldRun
    }

    private func shouldConsumeActiveClickAppExpose(for bundleIdentifier: String,
                                                   flags: CGEventFlags,
                                                   frontmostBefore: String?) -> Bool {
        let windowCount = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
        guard windowCount > 0 else { return false }

        let clickModifier = modifierCombination(from: flags)
        let clickSlot = appExposeSlotKey(for: .click, modifier: clickModifier)
        let requiresMultipleWindows = clickModifier == .none
            ? preferences.clickAppExposeRequiresMultipleWindows
            : preferences.appExposeMultipleWindowsRequired(slot: clickSlot)

        let canRunAppExpose = !requiresMultipleWindows || windowCount >= 2
        if canRunAppExpose,
           shouldUseDeferredDockLifecycleForActiveAppExpose(bundleIdentifier: bundleIdentifier,
                                                            flags: flags,
                                                            frontmostBefore: frontmostBefore) {
            Logger.debug("APP_EXPOSE_DECISION: click appExpose using deferred Dock pass-through path for \(bundleIdentifier)")
            return false
        }
        return DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .appExpose,
            canRunAppExpose: canRunAppExpose
        )
    }

    private func shouldSchedulePendingDockClickWatchdog(for context: PendingClickContext) -> Bool {
        guard modifierCombination(from: context.flags) == .none else { return false }
        guard preferences.firstClickBehavior == .activateApp else { return false }
        guard preferences.clickAction == .appExpose else { return false }
        guard !isRecentFirstClickActivatePassThrough(for: context.clickedBundle) else { return false }
        // This watchdog is only needed during first-click activation transitions.
        // When the clicked app is already frontmost, waiting for the real mouse-up
        // is required for active-app App Exposé trigger timing.
        guard context.frontmostBefore != context.clickedBundle else { return false }
        return true
    }

    private func schedulePendingDockClickWatchdog(context: PendingClickContext,
                                                  watchdogToken: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            guard watchdogToken == self.pendingDockClickWatchdogTokenCounter else { return }
            guard self.pendingClickContext?.clickSequence == context.clickSequence else { return }
            guard !self.pendingClickWasDragged else { return }
            guard let releasePoint = self.recoveryMouseUpPoint(from: context.location,
                                                               expectedBundle: context.clickedBundle,
                                                               action: nil) else {
                return
            }
            Logger.debug("WORKFLOW: Pending Dock click watchdog releasing click=\(context.clickSequence) bundle=\(context.clickedBundle) point=(\(Int(releasePoint.x)),\(Int(releasePoint.y)))")
            self.pendingClickContext = nil
            self.pendingClickWasDragged = false
            postSyntheticMouseUpPassthrough(at: releasePoint, flags: [])
        }
    }

    private func scheduleConsumedFollowUpClickWatchdog(context: PendingClickContext,
                                                       watchdogToken: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { return }
            guard watchdogToken == self.consumedFollowUpClickWatchdogTokenCounter else { return }
            guard self.pendingClickContext?.clickSequence == context.clickSequence else { return }
            guard !self.pendingClickWasDragged else { return }

            Logger.debug("WORKFLOW: Consumed follow-up click watchdog completing click=\(context.clickSequence) bundle=\(context.clickedBundle)")

            self.pendingClickContext = nil
            self.pendingClickWasDragged = false

            let consumeNow = self.executeClickAction(context)
            let shouldRecoverDockPressedState = consumeNow
                && self.shouldRecoverDockPressedState(after: self.lastActionExecuted,
                                                      bundleIdentifier: context.clickedBundle)
            if shouldRecoverDockPressedState {
                self.clickRecoveryTokenCounter += 1
                let recoveryToken = self.clickRecoveryTokenCounter
                self.scheduleDockPressedStateRecovery(at: context.location,
                                                      expectedBundle: context.clickedBundle,
                                                      clickToken: recoveryToken,
                                                      action: self.lastActionExecuted)
            }
        }
    }

    private func shouldUseDeferredDockLifecycleForActiveAppExpose(bundleIdentifier: String,
                                                                  flags: CGEventFlags,
                                                                  frontmostBefore: String?) -> Bool {
        guard modifierCombination(from: flags) == .none else { return false }
        guard frontmostBefore == bundleIdentifier else { return false }
        guard preferences.firstClickBehavior == .activateApp else { return false }
        guard preferences.clickAction == .appExpose else { return false }
        guard preferences.clickAppExposeRequiresMultipleWindows == false else { return false }
        guard appExposeInvocationToken == nil else { return false }
        guard lastTriggeredBundle == nil else { return false }
        guard currentExposeApp == nil else { return false }
        guard lastExposeDockClickBundle == nil else { return false }
        return true
    }

    private func performActivateAppAction(bundleIdentifier: String) -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        if !isRunning {
            Logger.debug("WORKFLOW: activateApp requested for non-running app \(bundleIdentifier); delegating launch to Dock")
            resetExposeTracking()
            return false
        }

        if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
            _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
        }

        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        resetExposeTracking()
        return true
    }

    private func performHideAppToggle(targetBundleIdentifier: String) -> Bool {
        // Hide App should toggle based on the target app's own visibility, not unrelated hidden apps.
        if WindowManager.isAppHidden(bundleIdentifier: targetBundleIdentifier) {
            _ = WindowManager.unhideApp(bundleIdentifier: targetBundleIdentifier)
            lastHideOthersTargetBundle = nil
        } else {
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundleIdentifier)
        }
        resetExposeTracking()
        return true
    }

    private func performHideOthersToggle(targetBundleIdentifier: String,
                                         allowUndoToggle: Bool = true) -> Bool {
        let shouldUndoHideOthers = allowUndoToggle
            && lastHideOthersTargetBundle == targetBundleIdentifier
            && WindowManager.anyHiddenOthers(excluding: targetBundleIdentifier)

        if shouldUndoHideOthers {
            _ = WindowManager.showAllApplications()
            lastHideOthersTargetBundle = nil
        } else {
            _ = WindowManager.hideOthers(bundleIdentifier: targetBundleIdentifier)
            lastHideOthersTargetBundle = targetBundleIdentifier
        }
        resetExposeTracking()
        return true
    }

    private func performSingleAppMode(targetBundleIdentifier: String,
                                      frontmostBefore: String?,
                                      allowTargetToggleOff: Bool = true,
                                      preferHideOthersBaseline: Bool = false) {
        let frontmostNow = FrontmostAppTracker.frontmostBundleIdentifier()
        let sourceBundleToHide = [frontmostBefore, frontmostNow]
            .compactMap { $0 }
            .first(where: { $0 != targetBundleIdentifier })
        let shouldHideOthersBaseline = preferHideOthersBaseline
            && (sourceBundleToHide == nil
                || sourceBundleToHide == "com.apple.finder"
                || sourceBundleToHide == "com.apple.dock")

        Logger.debug("WORKFLOW: Single app mode target=\(targetBundleIdentifier), frontmostBefore=\(frontmostBefore ?? "nil"), frontmostNow=\(frontmostNow ?? "nil"), sourceToHide=\(sourceBundleToHide ?? "nil"), hideOthersBaseline=\(shouldHideOthersBaseline)")

        if shouldHideOthersBaseline {
            _ = WindowManager.hideOthers(bundleIdentifier: targetBundleIdentifier)
        } else if let sourceBundleToHide {
            _ = WindowManager.hideAllWindows(bundleIdentifier: sourceBundleToHide)
        } else if allowTargetToggleOff && (frontmostBefore == targetBundleIdentifier || frontmostNow == targetBundleIdentifier) {
            // Toggle-off behavior when the user targets the current app.
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundleIdentifier)
            resetExposeTracking()
            return
        }

        let targetRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == targetBundleIdentifier }
        if targetRunning {
            if WindowManager.isAppHidden(bundleIdentifier: targetBundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: targetBundleIdentifier)
            }
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundleIdentifier)
        } else {
            launchApp(bundleIdentifier: targetBundleIdentifier)
        }

        resetExposeTracking()
    }

    private func performMinimizeToggle(bundleIdentifier: String) {
        if WindowManager.restoreAllWindows(bundleIdentifier: bundleIdentifier) {
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        } else {
            _ = WindowManager.minimizeAllWindows(bundleIdentifier: bundleIdentifier)
        }
    }
    
    private func shouldThrottleScrollToggle(action: DockAction,
                                             bundleIdentifier: String,
                                             now: TimeInterval) -> Bool {
        guard action == .hideApp || action == .hideOthers || action == .singleAppMode else {
            return false
        }
        let key = "\(bundleIdentifier)|\(action.rawValue)"
        if let last = lastScrollToggleTime[key], now - last < scrollToggleCooldown {
            return true
        }
        return false
    }

    private func markScrollToggle(action: DockAction,
                                  bundleIdentifier: String,
                                  now: TimeInterval) {
        let key = "\(bundleIdentifier)|\(action.rawValue)"
        lastScrollToggleTime[key] = now
    }

    private func shouldThrottleMinimize(bundleIdentifier: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastMinimizeToggleTime[bundleIdentifier], now - last < minimizeToggleCooldown {
            return true
        }
        return false
    }
    
    private func markMinimize(bundleIdentifier: String) {
        lastMinimizeToggleTime[bundleIdentifier] = Date().timeIntervalSinceReferenceDate
    }

    private func triggerAppExpose(for bundleIdentifier: String,
                                  deferredContext: DeferredAppExposeContext? = nil) {
        Logger.debug("WORKFLOW: Triggering App Exposé for \(bundleIdentifier)")

        let invocationToken = UUID()
        appExposeInvocationToken = invocationToken
        lastExposeInteractionAt = Date()
        let startedAt = Date()

        let frontmost = FrontmostAppTracker.frontmostBundleIdentifier()
        if frontmost != bundleIdentifier {
            if !WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier),
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                _ = WindowManager.activate(app)
            }
        }

        scheduleAppExposeInvocationCompletion(token: invocationToken,
                                              bundleIdentifier: bundleIdentifier,
                                              startedAt: startedAt,
                                              remainingAttempts: frontmost == bundleIdentifier ? 0 : 4,
                                              deferredContext: deferredContext)
    }

    private func scheduleDeferredAppExposeTrigger(for bundleIdentifier: String,
                                                  source: String,
                                                  origin: CGPoint? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            Logger.debug("WORKFLOW: Deferred App Exposé trigger source=\(source) target=\(bundleIdentifier)")
            self?.triggerAppExpose(for: bundleIdentifier,
                                   deferredContext: DeferredAppExposeContext(source: source, origin: origin))
        }
    }

    private func scheduleAppExposeInvocationCompletion(token: UUID,
                                                       bundleIdentifier: String,
                                                       startedAt: Date,
                                                       remainingAttempts: Int,
                                                       deferredContext: DeferredAppExposeContext?) {
        let delay: TimeInterval = remainingAttempts == 0 ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.appExposeInvocationToken == token else { return }

            let frontmost = FrontmostAppTracker.frontmostBundleIdentifier()
            if frontmost == bundleIdentifier || remainingAttempts == 0 {
                self.completeAppExposeInvocation(token: token,
                                                 bundleIdentifier: bundleIdentifier,
                                                 startedAt: startedAt,
                                                 deferredContext: deferredContext)
                return
            }

            Logger.debug("WORKFLOW: Waiting for App Exposé activation target=\(bundleIdentifier) frontmost=\(frontmost ?? "nil") remainingAttempts=\(remainingAttempts)")

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                if app.isHidden {
                    app.unhide()
                }
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
                _ = WindowManager.activate(app)
            }

            self.scheduleAppExposeInvocationCompletion(token: token,
                                                       bundleIdentifier: bundleIdentifier,
                                                       startedAt: startedAt,
                                                       remainingAttempts: remainingAttempts - 1,
                                                       deferredContext: deferredContext)
        }
    }
    
    private func exitAppExpose() {
        // Avoid synthetic Escape injection during rapid click churn.
        // Synthetic key events can interfere with Dock's own click/menu state machine.
        Logger.debug("WORKFLOW: Exiting App Exposé tracking (no synthetic Escape)")
        resetExposeTracking()
    }

    private func launchApp(bundleIdentifier: String) {
        Logger.debug("WORKFLOW: Launching app \(bundleIdentifier)")
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        if let url = url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                if let error = error {
                    Logger.debug("WORKFLOW: Failed to launch app \(bundleIdentifier): \(error.localizedDescription)")
                } else {
                    Logger.debug("WORKFLOW: Successfully launched app \(bundleIdentifier)")
                }
            }
        } else {
            Logger.debug("WORKFLOW: Could not find app URL for \(bundleIdentifier)")
        }
    }

    private func isRecentExposeInteraction(maxAge: TimeInterval = 2.0) -> Bool {
        guard let lastExposeInteractionAt else { return false }
        return Date().timeIntervalSince(lastExposeInteractionAt) <= maxAge
    }

    private func scheduleDockActivationAssertionIfNeeded(for bundleIdentifier: String,
                                                         frontmostBefore: String?,
                                                         reason: String) {
        guard frontmostBefore != bundleIdentifier else { return }

        activationAssertionTokenCounter += 1
        let token = activationAssertionTokenCounter

        let assertActivation: (TimeInterval, String) -> Void = { [weak self] delay, phase in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard token == self.activationAssertionTokenCounter else {
                    Logger.debug("APP_EXPOSE_DECISION: skipping stale activation assertion token=\(token) latest=\(self.activationAssertionTokenCounter) target=\(bundleIdentifier) phase=\(phase)")
                    return
                }
                guard self.appExposeInvocationToken == nil else { return }
                guard FrontmostAppTracker.frontmostBundleIdentifier() != bundleIdentifier else { return }
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                    return
                }

                if app.isHidden {
                    app.unhide()
                }
                _ = WindowManager.activate(app)
                Logger.debug("APP_EXPOSE_DECISION: activation assertion for \(bundleIdentifier) reason=\(reason) phase=\(phase) token=\(token)")
            }
        }

        // Two-phase assertion: a fast nudge, then a short retry for rapid multi-app churn.
        assertActivation(0.12, "fast")
        assertActivation(0.30, "retry")
    }
}
