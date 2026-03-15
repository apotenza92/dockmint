import AppKit

struct HotKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum AppExposeInvokeStrategy: String {
    case dockNotification = "dockNotification"
    case resolvedHotKey = "resolvedHotKey"
    case fallbackControlDown = "fallbackControlDown"
}

struct AppExposeInvokeResult {
    let dispatched: Bool
    let evidence: Bool
    let confirmed: Bool
    let strategy: AppExposeInvokeStrategy?
    let attempts: [String]
    let frontmostAfter: String
}

struct AppExposeDispatchReceipt {
    let dispatched: Bool
    let strategy: AppExposeInvokeStrategy?
    let attempts: [String]
    let frontmostAfterDispatch: String
}

private struct DockWindowSignature: Hashable {
    let windowNumber: Int
    let layer: Int
    let widthBucket: Int
    let heightBucket: Int
    let alphaBucket: Int
    let title: String
}

private struct AppExposeAttemptOutcome {
    let dispatched: Bool
    let evidence: Bool
    let strategy: AppExposeInvokeStrategy?
}

/// Triggers App Exposé via Dock private API.
@MainActor
final class AppExposeInvoker {
    private let appExposeDockNotification = "com.apple.expose.front.awake"
    private let evidenceSampleDelaysNs: [UInt64] = [60_000_000, 120_000_000, 180_000_000]

    // Diagnostics kept for UI/test compatibility.
    private(set) var lastResolvedHotKey: HotKey?
    private(set) var lastResolveError: String?
    private(set) var lastInvokeStrategy: AppExposeInvokeStrategy?
    private(set) var lastInvokeAttempts: [String] = []
    private(set) var lastForcedStrategy: String?

    @discardableResult
    func invokeApplicationWindows(for bundle: String,
                                  requireEvidence: Bool = true,
                                  completion: @escaping (AppExposeInvokeResult) -> Void) -> AppExposeDispatchReceipt {
        Logger.log("AppExposeInvoker: invokeApplicationWindows called for bundle \(bundle)")

        lastResolvedHotKey = nil
        lastResolveError = "not-used (private Dock notification path)"
        lastInvokeStrategy = nil
        lastInvokeAttempts = []
        lastForcedStrategy = nil

        let baselineDockSignature = dockWindowSignatureSnapshot()
        let posted = DockNotificationSender.post(notification: appExposeDockNotification)
        recordAttempt("dockNotification posted=\(posted)")
        Logger.log("AppExposeInvoker: attempt=dockNotification(\(appExposeDockNotification)) posted=\(posted)")

        let strategy: AppExposeInvokeStrategy? = posted ? .dockNotification : nil
        if posted {
            lastInvokeStrategy = .dockNotification
        }

        let receipt = AppExposeDispatchReceipt(
            dispatched: posted,
            strategy: strategy,
            attempts: lastInvokeAttempts,
            frontmostAfterDispatch: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        )

        guard posted else {
            completion(
                finalizeResult(
                    AppExposeAttemptOutcome(dispatched: false, evidence: false, strategy: nil),
                    requireEvidence: requireEvidence
                )
            )
            return receipt
        }

        guard requireEvidence else {
            Logger.log("AppExposeInvoker: selected strategy=dockNotification (evidence not required)")
            completion(
                finalizeResult(
                    AppExposeAttemptOutcome(dispatched: true,
                                            evidence: false,
                                            strategy: .dockNotification),
                    requireEvidence: false
                )
            )
            return receipt
        }

        Task { [weak self] in
            guard let self else { return }
            let evidence = await self.waitForExposeEvidence(baselineDockSignature: baselineDockSignature)
            self.recordAttempt("dockNotification evidence=\(evidence)")
            if evidence {
                Logger.log("AppExposeInvoker: selected strategy=dockNotification")
            } else {
                Logger.log("AppExposeInvoker: dock notification posted but no Expose evidence")
            }
            completion(
                self.finalizeResult(
                    AppExposeAttemptOutcome(dispatched: true,
                                            evidence: evidence,
                                            strategy: .dockNotification),
                    requireEvidence: true
                )
            )
        }

        return receipt
    }

    func isApplicationWindowsHotKeyConfigured() -> Bool {
        false
    }

    func isDockNotificationAvailable() -> Bool {
        DockNotificationSender.isAvailable
    }

    private func recordAttempt(_ attempt: String) {
        lastInvokeAttempts.append(attempt)
    }

    private func finalizeResult(_ outcome: AppExposeAttemptOutcome,
                                requireEvidence: Bool) -> AppExposeInvokeResult {
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let confirmed = DockDecisionEngine.appExposeInvocationConfirmed(dispatched: outcome.dispatched,
                                                                        evidence: outcome.evidence,
                                                                        requireEvidence: requireEvidence)
        return AppExposeInvokeResult(dispatched: outcome.dispatched,
                                     evidence: outcome.evidence,
                                     confirmed: confirmed,
                                     strategy: outcome.strategy,
                                     attempts: lastInvokeAttempts,
                                     frontmostAfter: frontmostAfter)
    }

    private func waitForExposeEvidence(baselineDockSignature: Set<DockWindowSignature>) async -> Bool {
        for delay in evidenceSampleDelaysNs {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return false
            }

            if isExposeEvidencePresent(baselineDockSignature: baselineDockSignature) {
                return true
            }
        }
        return isExposeEvidencePresent(baselineDockSignature: baselineDockSignature)
    }

    private func isExposeEvidencePresent(baselineDockSignature: Set<DockWindowSignature>) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost == "com.apple.dock" {
            return true
        }
        let dockAfter = dockWindowSignatureSnapshot()
        let delta = baselineDockSignature.symmetricDifference(dockAfter).count
        return delta > 0
    }

    private func dockWindowSignatureSnapshot() -> Set<DockWindowSignature> {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var signatures = Set<DockWindowSignature>()
        for window in raw {
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Dock" else {
                continue
            }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
            let title = (window[kCGWindowName as String] as? String) ?? ""
            let windowNumber = window[kCGWindowNumber as String] as? Int ?? -1
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = Int((bounds?["Width"] as? Double) ?? 0)
            let height = Int((bounds?["Height"] as? Double) ?? 0)
            signatures.insert(
                DockWindowSignature(windowNumber: windowNumber,
                                    layer: layer,
                                    widthBucket: width / 10,
                                    heightBucket: height / 10,
                                    alphaBucket: Int(alpha * 10.0),
                                    title: title)
            )
        }
        return signatures
    }
}

private enum DockNotificationSender {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let fn: CoreDockSendNotificationFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            Logger.log("DockNotificationSender: CoreDockSendNotification symbol unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    static var isAvailable: Bool {
        fn != nil
    }

    static func post(notification: String) -> Bool {
        guard let fn else { return false }
        fn(notification as CFString, nil)
        return true
    }
}
