import ApplicationServices
import CoreGraphics

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias CGSSpaceMask = UInt64

@_silgen_name("CGSMainConnectionID")
nonisolated private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
nonisolated private func CGSCopySpacesForWindows(_ cid: CGSConnectionID,
                                                 _ mask: CGSSpaceMask,
                                                 _ windowIDs: CFArray) -> CFArray?

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
nonisolated private func _AXUIElementGetWindow(_ axUIElement: AXUIElement,
                                               _ windowID: inout CGWindowID) -> AXError

enum WindowSpacePrivateApis {
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
}
