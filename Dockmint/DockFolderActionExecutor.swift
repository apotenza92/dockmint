import AppKit
import Foundation

enum DockFolderActionExecutor {
    enum ExecutionRoute: Equatable {
        case none
        case dock
        case finderPassthrough
        case finderScripted
        case customApplication
    }

    static func executionRoute(for action: DockFolderAction) -> ExecutionRoute {
        guard action.isConfigured else {
            return .none
        }

        if action.opensInDock {
            return .dock
        }

        if !action.opensInFinder {
            return .customApplication
        }

        // Finder passthrough keeps Finder in charge of any remembered window, view, group,
        // and sort state. Any explicit Finder option opts into Dockmint-managed automation.
        return action.isFinderPassthrough ? .finderPassthrough : .finderScripted
    }

    static func perform(_ action: DockFolderAction, folderURL: URL) -> Bool {
        guard folderURL.isFileURL else { return false }

        switch executionRoute(for: action) {
        case .none:
            return false
        case .dock:
            return openWithDock(action, folderURL: folderURL)
        case .finderPassthrough:
            return openInFinderPreservingExistingWindow(folderURL)
        case .customApplication:
            return open(folderURL, withApplicationIdentifier: action.openInApplicationIdentifier)
        case .finderScripted:
            let groupedSortBy = action.groupBy.defaultSortBy ?? action.sortBy
            let menuConfiguration = FinderMenuConfiguration(
                groupMenuItemTitle: groupMenuItemTitle(for: action.groupBy),
                groupedSortMenuItemTitle: sortMenuItemTitle(for: groupedSortBy),
                sortMenuItemTitle: action.groupBy == .none ? sortMenuItemTitle(for: action.sortBy) : nil
            )

            switch action.view {
            case .automatic:
                assert(menuConfiguration.requiresMenuAutomation,
                       "Finder automatic view should only take the scripted path when explicit group/sort overrides are present")
            case .icon, .list, .column:
                break
            }

            if menuConfiguration.requiresMenuAutomation {
                runFinderScript(for: folderURL,
                                view: configuredFinderView(for: action),
                                menuConfiguration: menuConfiguration)
                return true
            }

            switch action.view {
            case .automatic:
                return open(folderURL, withApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier)
            case .icon:
                runFinderScript(for: folderURL, view: .icon)
                return true
            case .list:
                runFinderScript(for: folderURL, view: .list)
                return true
            case .column:
                runFinderScript(for: folderURL, view: .column)
                return true
            }
        }
    }

    private struct FinderMenuConfiguration {
        let groupMenuItemTitle: String?
        let groupedSortMenuItemTitle: String?
        let sortMenuItemTitle: String?

        var requiresMenuAutomation: Bool {
            groupMenuItemTitle != nil || groupedSortMenuItemTitle != nil || sortMenuItemTitle != nil
        }
    }

    private static func openWithDock(_ action: DockFolderAction, folderURL: URL) -> Bool {
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard let dockItem = dockFolderItem(for: standardizedFolderURL) else {
            Logger.log("DockFolderActionExecutor: Failed to resolve Dock folder item for \(standardizedFolderURL.path)")
            return false
        }

        let result = AXUIElementPerformAction(dockItem, "AXPress" as CFString)
        if result != .success {
            Logger.log("DockFolderActionExecutor: Failed to open Dock stack for \(standardizedFolderURL.path) result=\(result.rawValue)")
            return false
        }

        return true
    }

    private static func dockFolderItem(for folderURL: URL) -> AXUIElement? {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }),
              let dockElement = dockApplicationElement(processIdentifier: dockApp.processIdentifier),
              let dockLists: [AXUIElement] = axAttribute(dockElement, attribute: kAXChildrenAttribute) else {
            return nil
        }

        let targetURL = folderURL.standardizedFileURL

        for list in dockLists {
            guard let children: [AXUIElement] = axAttribute(list, attribute: kAXChildrenAttribute) else {
                continue
            }

            for child in children {
                let subrole: String? = axAttribute(child, attribute: kAXSubroleAttribute)
                guard subrole == "AXFolderDockItem",
                      let itemURL: URL = axAttribute(child, attribute: kAXURLAttribute),
                      itemURL.standardizedFileURL == targetURL else {
                    continue
                }
                return child
            }
        }

        return nil
    }

    private static func dockApplicationElement(processIdentifier: pid_t) -> AXUIElement? {
        AXUIElementCreateApplication(processIdentifier)
    }

    private static func axAttribute<T>(_ element: AXUIElement, attribute: String) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }


    private static func openInFinderPreservingExistingWindow(_ folderURL: URL) -> Bool {
        let standardizedFolderURL = folderURL.standardizedFileURL
        if focusExistingFinderWindow(for: standardizedFolderURL) {
            Logger.debug("DockFolderActionExecutor: Reused existing Finder window for \(standardizedFolderURL.path)")
            return true
        }
        return open(standardizedFolderURL, withApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier)
    }

    private static func focusExistingFinderWindow(for folderURL: URL) -> Bool {
        let lines = [
            "tell application \"Finder\"",
            "activate",
            "set targetFolder to POSIX file \(appleScriptStringLiteral(folderURL.path)) as alias",
            "repeat with targetWindow in Finder windows",
            "try",
            "if (target of targetWindow as alias) is targetFolder then",
            "set index of targetWindow to 1",
            "return \"found\"",
            "end if",
            "end try",
            "end repeat",
            "return \"missing\"",
            "end tell"
        ]

        guard let output = runAppleScriptSync(lines) else {
            return false
        }

        return output == "found"
    }

    @discardableResult
    private static func open(_ folderURL: URL, withApplicationIdentifier identifier: String) -> Bool {
        guard let applicationURL = DockFolderOpenApplicationCatalog.applicationURL(for: identifier) else {
            Logger.log("DockFolderActionExecutor: Failed to resolve application for \(identifier)")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if let error {
                Logger.log("DockFolderActionExecutor: Failed to open folder with \(identifier): \(error.localizedDescription)")
            }
        }
        return true
    }

    private enum FinderView: String {
        case icon = "icon view"
        case list = "list view"
        case column = "column view"
    }

    private static func configuredFinderView(for action: DockFolderAction) -> FinderView? {
        if action.groupBy != .none || action.sortBy != .none {
            return action.view == .icon ? .icon : .list
        }

        switch action.view {
        case .automatic:
            return nil
        case .icon:
            return .icon
        case .list:
            return .list
        case .column:
            return .column
        }
    }

    private static func runFinderScript(for folderURL: URL,
                                        view: FinderView? = nil,
                                        menuConfiguration: FinderMenuConfiguration = FinderMenuConfiguration(
                                            groupMenuItemTitle: nil,
                                            groupedSortMenuItemTitle: nil,
                                            sortMenuItemTitle: nil
                                        )) {
        let folderPath = folderURL.path
        let lines = appleScriptLines(folderPath: folderPath, view: view, menuConfiguration: menuConfiguration)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = runAppleScriptSync(lines)
        }
    }

    @discardableResult
    private static func runAppleScriptSync(_ lines: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = lines.flatMap { ["-e", $0] }

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus != 0 {
                Logger.log("DockFolderActionExecutor: Finder script failed (\(task.terminationStatus)) output=\(output)")
                return nil
            }
            return output
        } catch {
            Logger.log("DockFolderActionExecutor: Failed to run Finder script: \(error.localizedDescription)")
            return nil
        }
    }

    private static func appleScriptLines(folderPath: String,
                                         view: FinderView?,
                                         menuConfiguration: FinderMenuConfiguration) -> [String] {
        var lines = [
            "tell application \"Finder\"",
            "activate",
            "set targetFolder to POSIX file \(appleScriptStringLiteral(folderPath)) as alias",
            "open targetFolder",
            "delay 0.08",
            "set targetWindow to front Finder window",
            "set target of targetWindow to targetFolder"
        ]

        if let view {
            lines.append("set current view of targetWindow to \(view.rawValue)")
        }

        if menuConfiguration.requiresMenuAutomation {
            lines += [
                "delay 0.12",
                "end tell",
                "tell application \"System Events\"",
                "tell process \"Finder\"",
                "tell menu 1 of menu bar item \"View\" of menu bar 1",
            ]

            if menuConfiguration.groupMenuItemTitle != nil {
                lines += [
                    "if exists menu item \"Use Groups\" then",
                    "set useGroupsMenuItem to menu item \"Use Groups\"",
                    "set groupsAreEnabled to value of attribute \"AXMenuItemMarkChar\" of useGroupsMenuItem is not missing value",
                    "if not groupsAreEnabled then click useGroupsMenuItem",
                    "delay 0.08",
                    "end if"
                ]

                if let groupMenuItemTitle = menuConfiguration.groupMenuItemTitle {
                    lines.append("if exists menu item \"Group by\" then click menu item \(appleScriptStringLiteral(groupMenuItemTitle)) of menu 1 of menu item \"Group by\"")
                }

                if let groupedSortMenuItemTitle = menuConfiguration.groupedSortMenuItemTitle {
                    lines += [
                        "delay 0.08",
                        "if exists menu item \"Sort Groups by\" then click menu item \(appleScriptStringLiteral(groupedSortMenuItemTitle)) of menu 1 of menu item \"Sort Groups by\""
                    ]
                }
            } else {
                lines += [
                    "if exists menu item \"Group by\" then",
                    "click menu item \"None\" of menu 1 of menu item \"Group by\"",
                    "delay 0.08",
                    "else if exists menu item \"Use Groups\" then",
                    "set useGroupsMenuItem to menu item \"Use Groups\"",
                    "if value of attribute \"AXMenuItemMarkChar\" of useGroupsMenuItem is not missing value then",
                    "click useGroupsMenuItem",
                    "delay 0.08",
                    "end if",
                    "end if"
                ]

                if let sortMenuItemTitle = menuConfiguration.sortMenuItemTitle {
                    lines += [
                        "if exists menu item \"Sort By\" then",
                        "click menu item \(appleScriptStringLiteral(sortMenuItemTitle)) of menu 1 of menu item \"Sort By\"",
                        "else if exists menu item \"Sort Stacks by\" then",
                        "click menu item \(appleScriptStringLiteral(sortMenuItemTitle)) of menu 1 of menu item \"Sort Stacks by\"",
                        "else if exists menu item \"Clean Up By\" then",
                        "click menu item \(appleScriptStringLiteral(sortMenuItemTitle)) of menu 1 of menu item \"Clean Up By\"",
                        "end if"
                    ]
                }
            }

            lines += [
                "end tell",
                "end tell",
                "end tell"
            ]
            return lines
        }

        lines.append("end tell")
        return lines
    }

    private static func sortMenuItemTitle(for sortBy: DockFolderSortBy) -> String? {
        switch sortBy {
        case .none:
            return nil
        case .name:
            return "Name"
        case .kind:
            return "Kind"
        case .dateLastOpened:
            return "Date Last Opened"
        case .dateAdded:
            return "Date Added"
        case .dateModified:
            return "Date Modified"
        case .dateCreated:
            return "Date Created"
        case .size:
            return "Size"
        case .tags:
            return "Tags"
        }
    }

    private static func groupMenuItemTitle(for groupBy: DockFolderGroupBy) -> String? {
        switch groupBy {
        case .none:
            return nil
        case .name:
            return "Name"
        case .kind:
            return "Kind"
        case .application:
            return "Application"
        case .dateLastOpened:
            return "Date Last Opened"
        case .dateAdded:
            return "Date Added"
        case .dateModified:
            return "Date Modified"
        case .dateCreated:
            return "Date Created"
        case .size:
            return "Size"
        case .tags:
            return "Tags"
        }
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
