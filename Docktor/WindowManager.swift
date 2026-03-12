import AppKit
import ApplicationServices

enum WindowManager {
    private static let braveBundleIdentifier = "com.brave.Browser"
    private static let braveAuxiliarySubroles: Set<String> = [
        "AXFloatingWindow",
        "AXSystemFloatingWindow",
        "AXUnknown"
    ]
    private static let minimumCandidateWindowSize = CGSize(width: 100, height: 100)

    private struct WindowCandidate {
        let axWindow: AXUIElement
        let cgWindowID: CGWindowID?
        let bounds: CGRect?
        let layer: Int?
        let alpha: Double?
        let isOnScreen: Bool
        let subrole: String?
        let spaceIDs: Set<Int>
        let isMinimized: Bool
    }

    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate()
    }

    /// Hide all windows of an app (Cmd+H equivalent)
    static func hideAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }

        // First try the direct NSRunningApplication hide.
        let hideRequested = app.hide()
        if hideRequested, waitForHidden(app, timeout: 0.35) {
            Logger.log("WindowManager: hide() succeeded for \(bundleIdentifier)")
            return true
        }

        if app.isHidden {
            Logger.log("WindowManager: App \(bundleIdentifier) already hidden; treating as success")
            return true
        }

        // Try Accessibility hide as a stronger fallback.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let hidden: CFBoolean = kCFBooleanTrue
        if AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, hidden) == .success,
           waitForHidden(app, timeout: 0.35) {
            Logger.log("WindowManager: AX hide succeeded for \(bundleIdentifier)")
            return true
        }

        // Final fallback: activate target app then send Cmd+H.
        _ = activate(app)
        let frontmost = waitForFrontmost(bundleIdentifier, timeout: 0.25)
            ? bundleIdentifier
            : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost == bundleIdentifier {
            let cmdHFallbacks: [(label: String, send: () -> Bool)] = [
                ("Cmd+H simple", { KeyChordSender.postSimple(keyCode: 4, flags: .maskCommand) }),
                ("Cmd+H full", { KeyChordSender.post(keyCode: 4, flags: .maskCommand) })
            ]
            for fallback in cmdHFallbacks {
                guard fallback.send() else { continue }
                if waitForHidden(app, timeout: 0.35) {
                    Logger.log("WindowManager: \(fallback.label) fallback succeeded for \(bundleIdentifier)")
                    return true
                }
            }
        }

        if pressHideMenuItem(for: app), waitForHidden(app, timeout: 0.35) {
            Logger.log("WindowManager: AX menu hide fallback succeeded for \(bundleIdentifier)")
            return true
        }

        Logger.log("WindowManager: Failed to hide \(bundleIdentifier) (hideRequested=\(hideRequested), frontmost=\(frontmost ?? "nil"))")
        return false
    }
    
    /// Unhide an app and activate it
    static func unhideApp(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot unhide")
            return false
        }
        app.unhide()
        _ = activate(app)
        Logger.log("WindowManager: Unhid and activated \(bundleIdentifier)")
        return true
    }
    
    /// Check if app is hidden
    static func isAppHidden(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier })?.isHidden ?? false
    }
    
    /// Minimize all windows of an app to the Dock
    static func minimizeAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        if app.isHidden {
            app.unhide()
        }
        let windowsArray = currentSpaceStandardWindows(for: app)
        guard !windowsArray.isEmpty else {
            Logger.log("WindowManager: No current-space standard windows to minimize for \(bundleIdentifier)")
            return false
        }
        
        var minimizedCount = 0
        for window in windowsArray {
            if isWindowMinimized(window) {
                continue // Already minimized
            }
            
            if setWindowMinimized(window, minimized: true) {
                minimizedCount += 1
            }
        }
        
        Logger.log("WindowManager: Minimized \(minimizedCount) current-space standard windows for \(bundleIdentifier)")
        return minimizedCount > 0
        
    }
    
    /// Restore all minimized windows of an app
    static func restoreAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        let windowsArray = currentSpaceStandardWindows(for: app)
        guard !windowsArray.isEmpty else {
            Logger.log("WindowManager: No current-space standard windows to restore for \(bundleIdentifier)")
            return false
        }
        
        var restoredCount = 0
        for window in windowsArray {
            if isWindowMinimized(window), setWindowMinimized(window, minimized: false) {
                restoredCount += 1
            }
        }
        
        Logger.log("WindowManager: Restored \(restoredCount) current-space standard windows for \(bundleIdentifier)")
        
        guard restoredCount > 0 else { return false }
        
        // Bring the app to the front.
        _ = activate(app)
        
        // Re-assert frontmost after a short delay to cover race conditions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            _ = activate(app)
        }
        
        return true
    }
    
    /// Check if all windows are minimized (and there is at least one window)
    static func allWindowsMinimized(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        
        let windowsArray = currentSpaceStandardWindows(for: app)
        guard !windowsArray.isEmpty else {
            return false
        }
        
        for window in windowsArray {
            if !isWindowMinimized(window) {
                return false
            }
        }
        return true
    }
    
    /// Check if an app has visible windows
    static func hasVisibleWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        
        let windowsArray = currentSpaceStandardWindows(for: app)
        guard !windowsArray.isEmpty else {
            return false
        }
        
        for window in windowsArray {
            if isWindowMinimized(window) {
                continue // Skip minimized windows
            }
            
            var hiddenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success,
               let isHidden = hiddenValue as? Bool, isHidden {
                continue // Skip hidden windows
            }
            
            // Found at least one visible, non-minimized window
            return true
        }
        
        return false
    }

    /// Count all AX windows currently reported by the application.
    static func totalWindowCount(bundleIdentifier: String) -> Int {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return 0
        }

        return globalStandardWindows(for: app).count
    }

    /// True when the app currently reports at least two windows.
    static func hasMultipleWindowsOpen(bundleIdentifier: String) -> Bool {
        totalWindowCount(bundleIdentifier: bundleIdentifier) >= 2
    }
    
    /// Get the main window of an app
    static func getMainWindow(bundleIdentifier: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        
        let pid = app.processIdentifier
        
        let appElement = AXUIElementCreateApplication(pid)
        var mainWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow)
        
        guard result == .success,
              let windowRef = mainWindow,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            // Try getting first window if no main window
            if let firstWindow = globalStandardWindows(for: app).first {
                return firstWindow
            }
            return nil
        }
        
        return (windowRef as! AXUIElement)
    }
    
    /// Activate an app and show its main window
    static func activateAndShowMainWindow(bundleIdentifier: String) -> Bool {
        // First, activate the app
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot activate")
            return false
        }
        
        _ = activate(app)
        
        // Wait a moment for app to activate, then show main window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let mainWindow = getMainWindow(bundleIdentifier: bundleIdentifier) {
                var position: CFTypeRef?
                if AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &position) == .success {
                    // Window exists, try to bring it forward
                    let frontmost: CFBoolean = kCFBooleanTrue
                    AXUIElementSetAttributeValue(mainWindow, kAXFrontmostAttribute as CFString, frontmost)
                }
            }
        }
        
        Logger.log("WindowManager: Activated app \(bundleIdentifier) and showing main window")
        return true
    }
    
    /// Quit an app gracefully
    static func quitApp(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot quit")
            return false
        }

        let terminateRequested = app.terminate()
        if waitForTermination(app, timeout: 0.8) {
            Logger.log("WindowManager: App \(bundleIdentifier) terminated gracefully")
            return true
        }

        Logger.log("WindowManager: terminate() did not finish for \(bundleIdentifier), requested=\(terminateRequested). Attempting forceTerminate.")
        _ = app.forceTerminate()
        if waitForTermination(app, timeout: 0.8) {
            Logger.log("WindowManager: App \(bundleIdentifier) force-terminated")
            return true
        }

        Logger.log("WindowManager: Failed to terminate \(bundleIdentifier)")
        return false
    }
    
    /// Bring all windows of an app to the front (without minimizing/restore)
    static func bringAllToFront(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        let windows = currentSpaceStandardWindows(for: app)
        guard !windows.isEmpty else {
            Logger.log("WindowManager: No current-space standard windows to bring front for \(bundleIdentifier)")
            return false
        }

        var restoredCount = 0
        for window in windows where isWindowMinimized(window) {
            if setWindowMinimized(window, minimized: false) {
                restoredCount += 1
            }
        }

        var raisedCount = 0
        for window in windows {
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                raisedCount += 1
            }
        }
        
        _ = activate(app)
        
        Logger.log("WindowManager: Raised \(raisedCount) current-space standard windows for \(bundleIdentifier) (restored=\(restoredCount))")
        return raisedCount > 0 || restoredCount > 0
    }
    
    /// Hide all other apps except the provided bundle
    static func hideOthers(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        // Activate target app first (and unhide if needed)
        if app.isHidden {
            app.unhide()
        }
        _ = activate(app)

        var hiddenCount = 0
        for other in NSWorkspace.shared.runningApplications {
            guard other.processIdentifier != app.processIdentifier,
                  other.activationPolicy == .regular,
                  !other.isTerminated,
                  !other.isHidden
            else {
                continue
            }

            if other.hide() {
                hiddenCount += 1
                continue
            }

            let element = AXUIElementCreateApplication(other.processIdentifier)
            let hidden: CFBoolean = kCFBooleanTrue
            if AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, hidden) == .success {
                hiddenCount += 1
            }
        }

        Logger.log("WindowManager: Hide others invoked for \(bundleIdentifier); hidden=\(hiddenCount)")
        return true
    }
    
    /// Show all apps (inverse of Hide Others)
    static func showAllApplications() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        var changed = false
        for app in apps {
            if app.isHidden {
                app.unhide()
                changed = true
            }
        }
        
        if changed {
            Logger.log("WindowManager: Show All - unhid applications")
            return true
        }

        Logger.log("WindowManager: Show All - no hidden apps found")
        return true
    }
    
    /// Check if any other app (excluding the provided bundle) is currently hidden.
    static func anyHiddenOthers(excluding bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            guard id != bundleIdentifier else { return false }
            guard app.activationPolicy == .regular else { return false }
            guard !app.isTerminated else { return false }
            return app.isHidden
        }
    }

    private static func waitForTermination(_ app: NSRunningApplication,
                                           timeout: TimeInterval,
                                           pollInterval: TimeInterval = 0.05) -> Bool {
        if app.isTerminated {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isTerminated {
                return true
            }

            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        return app.isTerminated
    }

    private static func waitForHidden(_ app: NSRunningApplication,
                                      timeout: TimeInterval,
                                      pollInterval: TimeInterval = 0.05) -> Bool {
        if app.isHidden {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isHidden {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }

        return app.isHidden
    }

    private static func waitForFrontmost(_ bundleIdentifier: String,
                                         timeout: TimeInterval,
                                         pollInterval: TimeInterval = 0.05) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }

        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    private static func pressHideMenuItem(for app: NSRunningApplication) -> Bool {
        guard let appName = app.localizedName else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBarRef = copyAXAttributeValue(element: appElement, attribute: kAXMenuBarAttribute) else {
            return false
        }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)
        guard let menuBarItems = copyAXAttributeValue(element: menuBar, attribute: kAXChildrenAttribute) as? [AXUIElement],
              let appMenuItem = menuBarItems.first(where: { axTitle(of: $0) == appName }) else {
            return false
        }

        guard AXUIElementPerformAction(appMenuItem, kAXPressAction as CFString) == .success else {
            return false
        }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))

        guard let appMenuChildren = copyAXAttributeValue(element: appMenuItem, attribute: kAXChildrenAttribute) as? [AXUIElement],
              let menu = appMenuChildren.first,
              let menuItems = copyAXAttributeValue(element: menu, attribute: kAXChildrenAttribute) as? [AXUIElement],
              let hideItem = menuItems.first(where: { item in
                  guard let title = axTitle(of: item) else { return false }
                  return title.hasPrefix("Hide ") && title != "Hide Others"
              }) else {
            return false
        }

        return AXUIElementPerformAction(hideItem, kAXPressAction as CFString) == .success
    }

    private static func copyAXAttributeValue(element: AXUIElement,
                                             attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axTitle(of element: AXUIElement) -> String? {
        copyAXAttributeValue(element: element, attribute: kAXTitleAttribute) as? String
    }

    private static func rawAppWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let rawWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return rawWindows
    }

    private static func globalStandardWindows(for app: NSRunningApplication) -> [AXUIElement] {
        rawAppWindows(for: app).filter { window in
            shouldIncludeGlobalStandardWindow(window, bundleIdentifier: app.bundleIdentifier)
        }
    }

    private static func currentSpaceStandardWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let activeSpaceIDs = currentActiveSpaceIDs()
        return windowCandidates(for: app)
            .filter { shouldIncludeCurrentSpaceStandardCandidate($0,
                                                                 bundleIdentifier: app.bundleIdentifier,
                                                                 activeSpaceIDs: activeSpaceIDs) }
            .map(\.axWindow)
    }

    private static func windowCandidates(for app: NSRunningApplication) -> [WindowCandidate] {
        let cgEntries = cgWindowEntries(for: app.processIdentifier)
        var usedWindowIDs = Set<CGWindowID>()

        return rawAppWindows(for: app).compactMap { window in
            makeWindowCandidate(window,
                                cgEntries: cgEntries,
                                usedWindowIDs: &usedWindowIDs)
        }
    }

    private static func shouldIncludeGlobalStandardCandidate(_ candidate: WindowCandidate,
                                                             bundleIdentifier: String?) -> Bool {
        guard shouldIncludeGlobalStandardWindow(candidate.axWindow, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard passesGeneralCandidateValidation(candidate) else {
            return false
        }

        return true
    }

    private static func shouldIncludeGlobalStandardWindow(_ window: AXUIElement,
                                                          bundleIdentifier: String?) -> Bool {
        guard roleIsWindow(window) else {
            return false
        }

        guard isStandardSubrole(stringAttribute(window, attribute: kAXSubroleAttribute as CFString)) else {
            return false
        }

        if bundleIdentifier == braveBundleIdentifier, isLikelyBraveAuxiliaryWindow(window) {
            let title = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "nil"
            let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? "nil"
            let identifier = stringAttribute(window, attribute: "AXIdentifier" as CFString) ?? "nil"
            Logger.debug("WindowManager: Excluding Brave auxiliary window title=\(title) subrole=\(subrole) identifier=\(identifier)")
            return false
        }

        return true
    }

    private static func shouldIncludeCurrentSpaceStandardCandidate(_ candidate: WindowCandidate,
                                                                   bundleIdentifier: String?,
                                                                   activeSpaceIDs: Set<Int>) -> Bool {
        guard shouldIncludeGlobalStandardCandidate(candidate, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard let layer = candidate.layer, layer == 0 else {
            return false
        }

        if !candidate.spaceIDs.isEmpty {
            return !candidate.spaceIDs.isDisjoint(with: activeSpaceIDs)
        }

        return candidate.isOnScreen
    }

    private static func isLikelyBraveAuxiliaryWindow(_ window: AXUIElement) -> Bool {
        let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
        if braveAuxiliarySubroles.contains(subrole) {
            return true
        }

        let textFields = [
            stringAttribute(window, attribute: kAXTitleAttribute as CFString),
            stringAttribute(window, attribute: "AXIdentifier" as CFString),
            stringAttribute(window, attribute: kAXDescriptionAttribute as CFString)
        ]
        let containsSidebarMarker = textFields
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("sidebar") || value.contains("side panel") || value.contains("sidepanel") || value.contains("vertical tabs")
            }
        guard containsSidebarMarker else {
            return false
        }

        let hasTrafficLightControls =
            hasElementAttribute(window, attribute: kAXCloseButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXMinimizeButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXZoomButtonAttribute as CFString)
        return !hasTrafficLightControls
    }

    private static func roleIsWindow(_ window: AXUIElement) -> Bool {
        guard let role = stringAttribute(window, attribute: kAXRoleAttribute as CFString) else {
            return true
        }
        return role == (kAXWindowRole as String)
    }

    private static func isStandardSubrole(_ subrole: String?) -> Bool {
        guard let subrole else {
            return true
        }
        if subrole.isEmpty {
            return true
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }

    private static func passesGeneralCandidateValidation(_ candidate: WindowCandidate) -> Bool {
        if let layer = candidate.layer, layer < 0 {
            return false
        }

        if let alpha = candidate.alpha, alpha <= 0.01 {
            return false
        }

        let size = candidate.bounds?.size ?? sizeAttribute(candidate.axWindow)
        guard let size else {
            return true
        }

        if size == .zero {
            return false
        }

        return size.width >= minimumCandidateWindowSize.width
            && size.height >= minimumCandidateWindowSize.height
    }

    private static func makeWindowCandidate(_ window: AXUIElement,
                                            cgEntries: [[String: AnyObject]],
                                            usedWindowIDs: inout Set<CGWindowID>) -> WindowCandidate? {
        let resolvedWindowID = resolveCGWindowID(for: window,
                                                 cgEntries: cgEntries,
                                                 usedWindowIDs: &usedWindowIDs)
        let matchingEntry = resolvedWindowID.flatMap { cgEntry(for: $0, in: cgEntries) }
        let bounds = matchingEntry.flatMap(boundsFromCGEntry)
        let layer = matchingEntry.flatMap { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue }
        let alpha = matchingEntry.flatMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue }
        let isOnScreen = matchingEntry.flatMap { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue } ?? false
        let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString)
        let isMinimized = isWindowMinimized(window)
        let spaceIDs = resolvedWindowID.map(WindowSpacePrivateApis.spaces(for:)) ?? []

        return WindowCandidate(axWindow: window,
                               cgWindowID: resolvedWindowID,
                               bounds: bounds,
                               layer: layer,
                               alpha: alpha,
                               isOnScreen: isOnScreen,
                               subrole: subrole,
                               spaceIDs: spaceIDs,
                               isMinimized: isMinimized)
    }

    private static func cgWindowEntries(for pid: pid_t) -> [[String: AnyObject]] {
        let rawEntries = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        return rawEntries.filter { entry in
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return ownerPID == pid
        }
    }

    private static func currentActiveSpaceIDs() -> Set<Int> {
        let entries = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        var activeSpaceIDs = Set<Int>()

        for entry in entries {
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard layer == 0, isOnScreen else {
                continue
            }

            let windowID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else {
                continue
            }

            activeSpaceIDs.formUnion(WindowSpacePrivateApis.spaces(for: windowID))
        }

        return activeSpaceIDs
    }

    private static func resolveCGWindowID(for window: AXUIElement,
                                          cgEntries: [[String: AnyObject]],
                                          usedWindowIDs: inout Set<CGWindowID>) -> CGWindowID? {
        if let directWindowID = WindowSpacePrivateApis.windowID(for: window), directWindowID != 0 {
            usedWindowIDs.insert(directWindowID)
            return directWindowID
        }

        let fallbackWindowID = mapAXWindowToCGWindowID(window,
                                                       cgEntries: cgEntries,
                                                       excluding: usedWindowIDs)
        if let fallbackWindowID {
            usedWindowIDs.insert(fallbackWindowID)
        }
        return fallbackWindowID
    }

    private static func mapAXWindowToCGWindowID(_ window: AXUIElement,
                                                cgEntries: [[String: AnyObject]],
                                                excluding usedWindowIDs: Set<CGWindowID>) -> CGWindowID? {
        let axTitle = (stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let axPosition = pointAttribute(window, attribute: kAXPositionAttribute as CFString)
        let axSize = sizeAttribute(window)
        let tolerance: CGFloat = 2.0

        if !axTitle.isEmpty,
           let titleMatch = cgEntries.first(where: { entry in
               let candidateTitle = ((entry[kCGWindowName as String] as? String) ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               return !usedWindowIDs.contains(candidateID) && candidateTitle == axTitle
           }) {
            return CGWindowID((titleMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        if let axPosition, let axSize, axSize != .zero,
           let boundsMatch = cgEntries.first(where: { entry in
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               guard !usedWindowIDs.contains(candidateID),
                     let candidateBounds = boundsFromCGEntry(entry) else {
                   return false
               }
               let positionMatch = abs(candidateBounds.origin.x - axPosition.x) <= tolerance
                   && abs(candidateBounds.origin.y - axPosition.y) <= tolerance
               let sizeMatch = abs(candidateBounds.size.width - axSize.width) <= tolerance
                   && abs(candidateBounds.size.height - axSize.height) <= tolerance
               return positionMatch && sizeMatch
           }) {
            return CGWindowID((boundsMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        if !axTitle.isEmpty,
           let fuzzyMatch = cgEntries.first(where: { entry in
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               guard !usedWindowIDs.contains(candidateID) else {
                   return false
               }
               let candidateTitle = ((entry[kCGWindowName as String] as? String) ?? "").lowercased()
               return candidateTitle.contains(axTitle.lowercased())
           }) {
            return CGWindowID((fuzzyMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        return nil
    }

    private static func cgEntry(for windowID: CGWindowID,
                                in cgEntries: [[String: AnyObject]]) -> [String: AnyObject]? {
        cgEntries.first { entry in
            let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return candidateID == windowID
        }
    }

    nonisolated private static func boundsFromCGEntry(_ entry: [String: AnyObject]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: AnyObject] else {
            return nil
        }

        let x = CGFloat((bounds["X"] as? NSNumber)?.doubleValue ?? .nan)
        let y = CGFloat((bounds["Y"] as? NSNumber)?.doubleValue ?? .nan)
        let width = CGFloat((bounds["Width"] as? NSNumber)?.doubleValue ?? .nan)
        let height = CGFloat((bounds["Height"] as? NSNumber)?.doubleValue ?? .nan)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
              let isMinimized = minimizedValue as? Bool else {
            return false
        }
        return isMinimized
    }

    private static func setWindowMinimized(_ window: AXUIElement, minimized: Bool) -> Bool {
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value) == .success
    }

    private static func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID(),
              AXValueGetType(axValue as! AXValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID(),
              AXValueGetType(axValue as! AXValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func hasElementAttribute(_ element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return false
        }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

}
