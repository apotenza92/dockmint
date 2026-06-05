import ApplicationServices
import CoreGraphics
import Foundation

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias CGSSpaceMask = UInt64
typealias CGSCopyWindowsOptions = Int
typealias CGSCopyWindowsTags = Int

@_silgen_name("CGSMainConnectionID")
nonisolated private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
nonisolated private func CGSCopySpacesForWindows(_ cid: CGSConnectionID,
                                                 _ mask: CGSSpaceMask,
                                                 _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGSCopyManagedDisplaySpaces")
nonisolated private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
nonisolated private func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID,
                                                          _ owner: Int,
                                                          _ spaces: CFArray,
                                                          _ options: CGSCopyWindowsOptions,
                                                          _ setTags: UnsafeMutablePointer<CGSCopyWindowsTags>,
                                                          _ clearTags: UnsafeMutablePointer<CGSCopyWindowsTags>) -> CFArray?

@_silgen_name("CGSGetWindowOwner")
@discardableResult
nonisolated private func CGSGetWindowOwner(_ cid: CGSConnectionID,
                                           _ windowID: CGWindowID,
                                           _ windowCID: UnsafeMutablePointer<CGSConnectionID>) -> CGError

@_silgen_name("CGSGetConnectionPSN")
@discardableResult
nonisolated private func CGSGetConnectionPSN(_ cid: CGSConnectionID,
                                             _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> CGError

@_silgen_name("GetProcessPID")
nonisolated private func DockmintGetProcessPID(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                               _ pid: UnsafeMutablePointer<pid_t>) -> Void

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
nonisolated private func _AXUIElementGetWindow(_ axUIElement: AXUIElement,
                                               _ windowID: inout CGWindowID) -> AXError

enum WindowSpacePrivateApis {
    // Matches AltTab's cross-Space enumeration mode. Including the undocumented
    // invisible-window bits can omit regular app windows on newer macOS builds.
    nonisolated private static let crossSpaceWindowsOptions: CGSCopyWindowsOptions = (1 << 1)
    nonisolated private static let managedSpaceCacheTTL: TimeInterval = 2.0
    nonisolated private static let managedSpaceCacheLock = NSLock()
    nonisolated(unsafe) private static var managedSpaceCache: (ids: [CGSSpaceID], expiresAt: Date)?

    nonisolated static func windowID(for axWindow: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    nonisolated static func spaces(for windowID: CGWindowID) -> Set<Int> {
        let allSpacesMask: CGSSpaceMask = 0xFFFF_FFFF_FFFF_FFFF
        let ids: CFArray = [NSNumber(value: UInt32(windowID))] as CFArray
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(),
                                                   allSpacesMask,
                                                   ids) as? [NSNumber] else {
            return []
        }
        return Set(spaces.map { Int($0.uint64Value) })
    }

    nonisolated static func managedSpaceIDs() -> [CGSSpaceID] {
        let now = Date()
        managedSpaceCacheLock.lock()
        if let cache = managedSpaceCache, cache.expiresAt > now {
            let ids = cache.ids
            managedSpaceCacheLock.unlock()
            return ids
        }
        managedSpaceCacheLock.unlock()

        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else {
            return []
        }

        let ids = displays.flatMap { display -> [CGSSpaceID] in
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return [] }
            return spaces.compactMap { space in
                if let id = space["id64"] as? UInt64 {
                    return id
                }
                if let number = space["id64"] as? NSNumber {
                    return number.uint64Value
                }
                return nil
            }
        }

        managedSpaceCacheLock.lock()
        managedSpaceCache = (ids, now.addingTimeInterval(managedSpaceCacheTTL))
        managedSpaceCacheLock.unlock()
        return ids
    }

    nonisolated static func windowIDs(in spaces: [CGSSpaceID], includeInvisible: Bool = true) -> Set<CGWindowID> {
        guard !spaces.isEmpty else { return [] }

        var setTags: CGSCopyWindowsTags = 0
        var clearTags: CGSCopyWindowsTags = 0
        let options = crossSpaceWindowsOptions
        let spaceNumbers = spaces.map { NSNumber(value: $0) } as CFArray

        guard let windowIDs = CGSCopyWindowsWithOptionsAndTags(CGSMainConnectionID(),
                                                               0,
                                                               spaceNumbers,
                                                               options,
                                                               &setTags,
                                                               &clearTags) as? [NSNumber] else {
            return []
        }

        return Set(windowIDs.map { CGWindowID($0.uint32Value) }.filter { $0 != 0 })
    }

    nonisolated static func ownerPID(for windowID: CGWindowID) -> pid_t? {
        var windowCID: CGSConnectionID = 0
        guard CGSGetWindowOwner(CGSMainConnectionID(), windowID, &windowCID) == .success,
              windowCID != 0 else {
            return nil
        }

        var psn = ProcessSerialNumber()
        guard CGSGetConnectionPSN(windowCID, &psn) == .success else {
            return nil
        }

        var pid: pid_t = 0
        DockmintGetProcessPID(&psn, &pid)
        guard pid != 0 else {
            return nil
        }

        return pid
    }
}
