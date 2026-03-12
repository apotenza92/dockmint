import AppKit
import Foundation
import Combine
import ServiceManagement
import SwiftUI

enum DockAction: String, CaseIterable, Codable {
    case none = "none"
    case activateApp = "activateApp"
    case hideApp = "hideApp"
    case appExpose = "appExpose"
    case minimizeAll = "minimizeAll"
    case quitApp = "quitApp"
    case bringAllToFront = "bringAllToFront"
    case hideOthers = "hideOthers"
    case singleAppMode = "singleAppMode"

    var displayName: String {
        switch self {
        case .none: return "-"
        case .activateApp: return "Activate App"
        case .hideApp: return "Hide App"
        case .appExpose: return "App Exposé"
        case .minimizeAll: return "Minimize All"
        case .quitApp: return "Quit App"
        case .bringAllToFront: return "Bring All to Front"
        case .hideOthers: return "Hide Others"
        case .singleAppMode: return "Single App Mode"
        }
    }
}

struct DockFolderOpenApplicationOption: Identifiable, Hashable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
    var isFinder: Bool { identifier == DockFolderOpenApplicationCatalog.finderBundleIdentifier }

    static let none = DockFolderOpenApplicationOption(identifier: DockFolderOpenApplicationCatalog.noneIdentifier,
                                                      displayName: "-")
}

enum DockFolderOpenApplicationCatalog {
    static let noneIdentifier = "none"
    static let dockIdentifier = "dock"
    static let finderBundleIdentifier = "com.apple.finder"

    private static let additionalBundleIdentifiers = [
        finderBundleIdentifier,
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed"
    ]

    @MainActor
    static func options(including selectedIdentifier: String? = nil) -> [DockFolderOpenApplicationOption] {
        DockFolderOpenApplicationOptionsCache.shared.options(including: selectedIdentifier)
    }

    @MainActor
    static func refreshOptionsCache() {
        DockFolderOpenApplicationOptionsCache.shared.refresh()
    }

    static func minimalOptions() -> [DockFolderOpenApplicationOption] {
        [
            .none,
            DockFolderOpenApplicationOption(identifier: dockIdentifier, displayName: "Dock"),
            DockFolderOpenApplicationOption(identifier: finderBundleIdentifier, displayName: "Finder")
        ]
    }

    static func placeholderOption(for identifier: String) -> DockFolderOpenApplicationOption {
        DockFolderOpenApplicationOption(
            identifier: normalize(identifier),
            displayName: "Missing App (\(normalize(identifier)))"
        )
    }

    fileprivate static func discoveredOptions() -> [DockFolderOpenApplicationOption] {
        var optionsByIdentifier: [String: DockFolderOpenApplicationOption] = Dictionary(
            uniqueKeysWithValues: minimalOptions().map { ($0.identifier, $0) }
        )

        for applicationURL in discoveredApplicationURLs() {
            guard let option = option(for: applicationURL) else { continue }
            optionsByIdentifier[option.identifier] = option
        }

        for bundleIdentifier in additionalBundleIdentifiers {
            guard let option = option(forBundleIdentifier: bundleIdentifier) else { continue }
            optionsByIdentifier[option.identifier] = option
        }

        let sortedApplications = optionsByIdentifier.values
            .filter { $0.identifier != noneIdentifier && $0.identifier != dockIdentifier }
            .sorted { lhs, rhs in
                if lhs.isFinder != rhs.isFinder {
                    return lhs.isFinder
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

        return [
            .none,
            DockFolderOpenApplicationOption(identifier: dockIdentifier, displayName: "Dock")
        ] + sortedApplications
    }

    static func applicationURL(for identifier: String) -> URL? {
        let normalizedIdentifier = normalize(identifier)
        guard normalizedIdentifier != noneIdentifier, normalizedIdentifier != dockIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedIdentifier)
    }

    static func isFinder(_ identifier: String) -> Bool {
        normalize(identifier) == finderBundleIdentifier
    }

    static func isDock(_ identifier: String) -> Bool {
        normalize(identifier) == dockIdentifier
    }

    static func normalize(_ identifier: String) -> String {
        switch identifier {
        case "", noneIdentifier:
            return noneIdentifier
        case dockIdentifier, "com.apple.dock":
            return dockIdentifier
        case "finder":
            return finderBundleIdentifier
        default:
            return identifier
        }
    }

    private static func discoveredApplicationURLs() -> [URL] {
        guard #available(macOS 12.0, *) else { return [] }
        let sampleFolderURL = FileManager.default.homeDirectoryForCurrentUser
        return NSWorkspace.shared.urlsForApplications(toOpen: sampleFolderURL)
    }

    private static func option(for applicationURL: URL) -> DockFolderOpenApplicationOption? {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            return nil
        }
        return DockFolderOpenApplicationOption(identifier: bundleIdentifier,
                                               displayName: FileManager.default.displayName(atPath: applicationURL.path))
    }

    private static func option(forBundleIdentifier bundleIdentifier: String) -> DockFolderOpenApplicationOption? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return DockFolderOpenApplicationOption(identifier: bundleIdentifier,
                                               displayName: FileManager.default.displayName(atPath: applicationURL.path))
    }
}

@MainActor
final class DockFolderOpenApplicationOptionsCache {
    static let shared = DockFolderOpenApplicationOptionsCache()

    private var cachedOptions: [DockFolderOpenApplicationOption]

    private init() {
        cachedOptions = DockFolderOpenApplicationCatalog.discoveredOptions()
    }

    func options(including selectedIdentifier: String? = nil) -> [DockFolderOpenApplicationOption] {
        let normalizedSelectedIdentifier = DockFolderOpenApplicationCatalog.normalize(
            selectedIdentifier ?? DockFolderOpenApplicationCatalog.noneIdentifier
        )
        guard normalizedSelectedIdentifier != DockFolderOpenApplicationCatalog.noneIdentifier,
              cachedOptions.contains(where: { $0.identifier == normalizedSelectedIdentifier }) == false else {
            return cachedOptions
        }

        var options = cachedOptions
        options.append(DockFolderOpenApplicationCatalog.placeholderOption(for: normalizedSelectedIdentifier))
        return options
    }

    func refresh() {
        cachedOptions = DockFolderOpenApplicationCatalog.discoveredOptions()
    }
}

enum DockFolderView: String, CaseIterable, Codable {
    case automatic
    case icon
    case list
    case column

    var displayName: String {
        switch self {
        case .automatic: return "Finder Default"
        case .icon: return "Icon"
        case .list: return "List"
        case .column: return "Column"
        }
    }
}

enum DockFolderSortBy: String, CaseIterable, Codable {
    case none
    case name
    case kind
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .name: return "Name"
        case .kind: return "Kind"
        case .dateLastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }
}

enum DockFolderGroupBy: String, CaseIterable, Codable {
    case none
    case name
    case kind
    case application
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var displayName: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .application: return "Application"
        case .dateLastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }

    var defaultSortBy: DockFolderSortBy? {
        switch self {
        case .none:
            return nil
        case .name:
            return .name
        case .kind:
            return .kind
        case .application:
            return .name
        case .dateLastOpened:
            return .dateLastOpened
        case .dateAdded:
            return .dateAdded
        case .dateModified:
            return .dateModified
        case .dateCreated:
            return .dateCreated
        case .size:
            return .size
        case .tags:
            return .tags
        }
    }
}

enum DockFolderStackSortBy: String, CaseIterable, Codable {
    case current
    case name
    case dateAdded
    case dateModified
    case dateCreated
    case kind

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .kind: return "Kind"
        }
    }
}

enum DockFolderStackDisplayAs: String, CaseIterable, Codable {
    case current
    case folder
    case stack

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .folder: return "Folder"
        case .stack: return "Stack"
        }
    }
}

enum DockFolderStackViewContentAs: String, CaseIterable, Codable {
    case current
    case fan
    case grid
    case list
    case automatic

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .fan: return "Fan"
        case .grid: return "Grid"
        case .list: return "List"
        case .automatic: return "Automatic"
        }
    }
}

struct DockFolderAction: Codable, Equatable {
    var openInApplicationIdentifier: String
    var view: DockFolderView
    var sortBy: DockFolderSortBy
    var groupBy: DockFolderGroupBy
    var dockSortBy: DockFolderStackSortBy
    var dockDisplayAs: DockFolderStackDisplayAs
    var dockViewContentAs: DockFolderStackViewContentAs

    static let none = DockFolderAction(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.noneIdentifier,
                                       view: .automatic,
                                       sortBy: .none,
                                       groupBy: .none,
                                       dockSortBy: .current,
                                       dockDisplayAs: .current,
                                       dockViewContentAs: .current)

    var isConfigured: Bool {
        DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier) != DockFolderOpenApplicationCatalog.noneIdentifier
    }

    var opensInFinder: Bool {
        DockFolderOpenApplicationCatalog.isFinder(openInApplicationIdentifier)
    }

    var opensInDock: Bool {
        DockFolderOpenApplicationCatalog.isDock(openInApplicationIdentifier)
    }

    var isFinderPassthrough: Bool {
        opensInFinder && view == .automatic
    }

    var appliesDockOverrides: Bool {
        dockSortBy != .current || dockDisplayAs != .current || dockViewContentAs != .current
    }

    var storageValue: String {
        "\(DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier))|\(view.rawValue)|\(sortBy.rawValue)|\(groupBy.rawValue)|\(dockSortBy.rawValue)|\(dockDisplayAs.rawValue)|\(dockViewContentAs.rawValue)"
    }

    var debugName: String {
        if !isConfigured {
            return "none"
        }
        return storageValue
    }

    init(openInApplicationIdentifier: String,
         view: DockFolderView,
         sortBy: DockFolderSortBy,
         groupBy: DockFolderGroupBy = .none,
         dockSortBy: DockFolderStackSortBy = .current,
         dockDisplayAs: DockFolderStackDisplayAs = .current,
         dockViewContentAs: DockFolderStackViewContentAs = .current) {
        self.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier)
        self.view = view
        if view == .automatic {
            self.sortBy = .none
            self.groupBy = .none
        } else {
            self.sortBy = sortBy
            self.groupBy = groupBy
        }
        self.dockSortBy = dockSortBy
        self.dockDisplayAs = dockDisplayAs
        self.dockViewContentAs = dockViewContentAs
    }

    init(storageValue: String) {
        let parts = storageValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 7,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]),
           let groupBy = DockFolderGroupBy(rawValue: parts[3]),
           let dockSortBy = DockFolderStackSortBy(rawValue: parts[4]),
           let dockDisplayAs = DockFolderStackDisplayAs(rawValue: parts[5]),
           let dockViewContentAs = DockFolderStackViewContentAs(rawValue: parts[6]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: groupBy,
                      dockSortBy: dockSortBy,
                      dockDisplayAs: dockDisplayAs,
                      dockViewContentAs: dockViewContentAs)
            return
        }

        if parts.count == 4,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]),
           let groupBy = DockFolderGroupBy(rawValue: parts[3]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: groupBy,
                      dockSortBy: .current,
                      dockDisplayAs: .current,
                      dockViewContentAs: .current)
            return
        }

        if parts.count == 3,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: .none,
                      dockSortBy: .current,
                      dockDisplayAs: .current,
                      dockViewContentAs: .current)
            return
        }

        switch storageValue {
        case "openFolder":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .automatic,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderIconView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .icon,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderListView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderColumnView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .column,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderSortByName":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .name,
                      groupBy: .none)
        case "openFolderSortByDateModified":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .dateModified,
                      groupBy: .none)
        default:
            self = .none
        }
    }
}

enum FirstClickBehavior: String, CaseIterable, Codable {
    case activateApp = "activateApp"
    case bringAllToFront = "bringAllToFront"
    case appExpose = "appExpose"

    var displayName: String {
        switch self {
        case .activateApp: return "Activate App"
        case .bringAllToFront: return "Bring All to Front"
        case .appExpose: return "App Exposé"
        }
    }
}

enum UpdateCheckFrequency: String, CaseIterable, Codable, Identifiable {
    case never
    case startup
    case hourly
    case sixHours
    case twelveHours
    case daily
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never:
            return "Never"
        case .startup:
            return "On Startup"
        case .hourly:
            return "Every Hour"
        case .sixHours:
            return "Every 6 Hours"
        case .twelveHours:
            return "Every 12 Hours"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .hourly:
            return 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .never, .startup:
            return nil
        }
    }
}

enum AppExposeSlotSource: String {
    case click
    case firstClick
    case scrollUp
    case scrollDown
}

enum AppExposeSlotModifier: String {
    case none
    case shift
    case option
    case shiftOption
}

enum AppExposeSlotKey {
    static func make(source: AppExposeSlotSource, modifier: AppExposeSlotModifier) -> String {
        make(source: source.rawValue, modifier: modifier.rawValue)
    }

    static func make(source: String, modifier: String) -> String {
        "\(source)_\(modifier)"
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let userDefaults = UserDefaults.standard
    private let settingsStore: SettingsStore
    private let clickActionKey = "clickAction"
    private let shiftClickActionKey = "shiftClickAction"
    private let optionClickActionKey = "optionClickAction"
    private let shiftOptionClickActionKey = "shiftOptionClickAction"
    private let scrollUpActionKey = "scrollUpAction"
    private let shiftScrollUpActionKey = "shiftScrollUpAction"
    private let optionScrollUpActionKey = "optionScrollUpAction"
    private let shiftOptionScrollUpActionKey = "shiftOptionScrollUpAction"
    private let scrollDownActionKey = "scrollDownAction"
    private let shiftScrollDownActionKey = "shiftScrollDownAction"
    private let optionScrollDownActionKey = "optionScrollDownAction"
    private let shiftOptionScrollDownActionKey = "shiftOptionScrollDownAction"
    private let folderClickActionKey = "folderClickAction"
    private let shiftFolderClickActionKey = "shiftFolderClickAction"
    private let optionFolderClickActionKey = "optionFolderClickAction"
    private let shiftOptionFolderClickActionKey = "shiftOptionFolderClickAction"
    private let folderScrollUpActionKey = "folderScrollUpAction"
    private let shiftFolderScrollUpActionKey = "shiftFolderScrollUpAction"
    private let optionFolderScrollUpActionKey = "optionFolderScrollUpAction"
    private let shiftOptionFolderScrollUpActionKey = "shiftOptionFolderScrollUpAction"
    private let folderScrollDownActionKey = "folderScrollDownAction"
    private let shiftFolderScrollDownActionKey = "shiftFolderScrollDownAction"
    private let optionFolderScrollDownActionKey = "optionFolderScrollDownAction"
    private let shiftOptionFolderScrollDownActionKey = "shiftOptionFolderScrollDownAction"
    private let scrollDefaultsMigratedKey = "scrollDefaultsMigrated_v3"
    private let behaviorDefaultsMigratedKey = "behaviorDefaultsMigrated_v4"
    private let modifierDefaultsMigratedKey = "modifierDefaultsMigrated_v5"
    private let showOnStartupKey = "showOnStartup"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let firstLaunchCompletedKey = "firstLaunchCompleted"
    private let startAtLoginKey = "startAtLogin"
    private let updateCheckFrequencyKey = "updateCheckFrequency"
    private let lastUpdateCheckTimestampKey = "lastUpdateCheckTimestamp"
    private let firstClickBehaviorKey = "firstClickBehavior"
    private let firstClickShiftActionKey = "firstClickShiftAction"
    private let firstClickOptionActionKey = "firstClickOptionAction"
    private let firstClickShiftOptionActionKey = "firstClickShiftOptionAction"
    private let firstClickAppExposeRequiresMultipleWindowsKey = "firstClickAppExposeRequiresMultipleWindows"
    private let clickAppExposeRequiresMultipleWindowsKey = "clickAppExposeRequiresMultipleWindows"
    private let appExposeRequiresMultipleWindowsMapKey = "appExposeRequiresMultipleWindowsMap"
    private let firstClickModifierActionsMigratedKey = "firstClickModifierActionsMigrated_v6"
    private let appExposeRequiresMultipleWindowsMapMigratedKey = "appExposeRequiresMultipleWindowsMapMigrated_v7"

    private static let showOnStartupPreferenceKey = PreferenceKey<Bool>(name: "showOnStartup", defaultValue: false)
    private static let showMenuBarIconPreferenceKey = PreferenceKey<Bool>(name: "showMenuBarIcon", defaultValue: true)
    private static let firstLaunchCompletedPreferenceKey = PreferenceKey<Bool>(name: "firstLaunchCompleted", defaultValue: false)
    private static let updateCheckFrequencyPreferenceKey = PreferenceKey<UpdateCheckFrequency>(name: "updateCheckFrequency", defaultValue: .weekly)
    private static let firstClickBehaviorPreferenceKey = PreferenceKey<FirstClickBehavior>(name: "firstClickBehavior", defaultValue: .activateApp)
    private static let lastUpdateCheckTimestampPreferenceKey = PreferenceKey<Double>(name: "lastUpdateCheckTimestamp", defaultValue: 0)

    // Prevent feedback loop when we adjust login item after a failed toggle.
    private var applyingLoginItemChange = false

    private static var isAutomatedTestSuite: Bool {
        ProcessInfo.processInfo.environment["DOCKTOR_TEST_SUITE"] == "1"
    }

    @Published var clickAction: DockAction {
        didSet {
            userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
        }
    }

    @Published var firstClickBehavior: FirstClickBehavior {
        didSet {
            settingsStore.set(firstClickBehavior, for: Self.firstClickBehaviorPreferenceKey)
        }
    }

    @Published var firstClickAppExposeRequiresMultipleWindows: Bool {
        didSet {
            userDefaults.set(firstClickAppExposeRequiresMultipleWindows, forKey: firstClickAppExposeRequiresMultipleWindowsKey)
        }
    }

    @Published var clickAppExposeRequiresMultipleWindows: Bool {
        didSet {
            userDefaults.set(clickAppExposeRequiresMultipleWindows, forKey: clickAppExposeRequiresMultipleWindowsKey)
        }
    }

    /// Per-slot ">1 window" gate for modifier rows and scroll rows.
    /// Keys follow the pattern "<source>_<modifier>", e.g. "firstClick_shift", "scrollUp_none".
    /// The no-modifier first-click and active-app-click slots are stored in their own legacy keys above.
    @Published var appExposeRequiresMultipleWindowsMap: [String: Bool] {
        didSet {
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
        }
    }

    func appExposeMultipleWindowsRequired(slot: String) -> Bool {
        appExposeRequiresMultipleWindowsMap[slot] ?? legacyAppExposeMultipleWindowsDefault(forSlot: slot)
    }

    func appExposeMultipleWindowsBinding(slot: String) -> Binding<Bool> {
        Binding(
            get: { self.appExposeRequiresMultipleWindowsMap[slot] ?? self.legacyAppExposeMultipleWindowsDefault(forSlot: slot) },
            set: { self.appExposeRequiresMultipleWindowsMap[slot] = $0 }
        )
    }

    private func legacyAppExposeMultipleWindowsDefault(forSlot slot: String) -> Bool {
        if slot.hasPrefix("\(AppExposeSlotSource.firstClick.rawValue)_") {
            return firstClickAppExposeRequiresMultipleWindows
        }
        return clickAppExposeRequiresMultipleWindows
    }

    @Published var firstClickShiftAction: DockAction {
        didSet {
            userDefaults.set(firstClickShiftAction.rawValue, forKey: firstClickShiftActionKey)
        }
    }

    @Published var firstClickOptionAction: DockAction {
        didSet {
            userDefaults.set(firstClickOptionAction.rawValue, forKey: firstClickOptionActionKey)
        }
    }

    @Published var firstClickShiftOptionAction: DockAction {
        didSet {
            userDefaults.set(firstClickShiftOptionAction.rawValue, forKey: firstClickShiftOptionActionKey)
        }
    }

    @Published var shiftClickAction: DockAction {
        didSet {
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
        }
    }

    @Published var optionClickAction: DockAction {
        didSet {
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
        }
    }

    @Published var shiftOptionClickAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
        }
    }

    @Published var folderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(folderClickAction.storageValue, forKey: folderClickActionKey)
        }
    }

    @Published var shiftFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderClickAction.storageValue, forKey: shiftFolderClickActionKey)
        }
    }

    @Published var optionFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderClickAction.storageValue, forKey: optionFolderClickActionKey)
        }
    }

    @Published var shiftOptionFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderClickAction.storageValue, forKey: shiftOptionFolderClickActionKey)
        }
    }

    @Published var scrollUpAction: DockAction {
        didSet {
            userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
        }
    }

    @Published var shiftScrollUpAction: DockAction {
        didSet {
            userDefaults.set(shiftScrollUpAction.rawValue, forKey: shiftScrollUpActionKey)
        }
    }

    @Published var optionScrollUpAction: DockAction {
        didSet {
            userDefaults.set(optionScrollUpAction.rawValue, forKey: optionScrollUpActionKey)
        }
    }

    @Published var shiftOptionScrollUpAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionScrollUpAction.rawValue, forKey: shiftOptionScrollUpActionKey)
        }
    }

    @Published var folderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(folderScrollUpAction.storageValue, forKey: folderScrollUpActionKey)
        }
    }

    @Published var shiftFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderScrollUpAction.storageValue, forKey: shiftFolderScrollUpActionKey)
        }
    }

    @Published var optionFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderScrollUpAction.storageValue, forKey: optionFolderScrollUpActionKey)
        }
    }

    @Published var shiftOptionFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderScrollUpAction.storageValue, forKey: shiftOptionFolderScrollUpActionKey)
        }
    }

    @Published var scrollDownAction: DockAction {
        didSet {
            userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
        }
    }

    @Published var shiftScrollDownAction: DockAction {
        didSet {
            userDefaults.set(shiftScrollDownAction.rawValue, forKey: shiftScrollDownActionKey)
        }
    }

    @Published var optionScrollDownAction: DockAction {
        didSet {
            userDefaults.set(optionScrollDownAction.rawValue, forKey: optionScrollDownActionKey)
        }
    }

    @Published var shiftOptionScrollDownAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionScrollDownAction.rawValue, forKey: shiftOptionScrollDownActionKey)
        }
    }

    @Published var folderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(folderScrollDownAction.storageValue, forKey: folderScrollDownActionKey)
        }
    }

    @Published var shiftFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderScrollDownAction.storageValue, forKey: shiftFolderScrollDownActionKey)
        }
    }

    @Published var optionFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderScrollDownAction.storageValue, forKey: optionFolderScrollDownActionKey)
        }
    }

    @Published var shiftOptionFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderScrollDownAction.storageValue, forKey: shiftOptionFolderScrollDownActionKey)
        }
    }

    @Published var showOnStartup: Bool {
        didSet {
            settingsStore.set(showOnStartup, for: Self.showOnStartupPreferenceKey)
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            settingsStore.set(showMenuBarIcon, for: Self.showMenuBarIconPreferenceKey)
        }
    }

    @Published var firstLaunchCompleted: Bool {
        didSet {
            settingsStore.set(firstLaunchCompleted, for: Self.firstLaunchCompletedPreferenceKey)
        }
    }

    @Published var startAtLogin: Bool {
        didSet {
            guard !applyingLoginItemChange else { return }
            applyingLoginItemChange = true
            do {
                if startAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                userDefaults.set(startAtLogin, forKey: startAtLoginKey)
            } catch {
                Logger.log("Failed to update login item state: \(error.localizedDescription)")
                // Revert to actual system state to keep UI truthful
                let enabled = SMAppService.mainApp.status == .enabled
                startAtLogin = enabled
                userDefaults.set(enabled, forKey: startAtLoginKey)
            }
            applyingLoginItemChange = false
        }
    }

    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            settingsStore.set(updateCheckFrequency, for: Self.updateCheckFrequencyPreferenceKey)
        }
    }

    private init() {
        self.settingsStore = SettingsStore(defaults: UserDefaults.standard)

        // Load base mappings from UserDefaults or use defaults.
        var clickAction: DockAction
        if let clickRaw = userDefaults.string(forKey: clickActionKey),
           let click = DockAction(rawValue: clickRaw) {
            clickAction = click
        } else {
            clickAction = .appExpose
        }

        var scrollUpAction: DockAction
        if let scrollUpRaw = userDefaults.string(forKey: scrollUpActionKey),
           let scrollUp = DockAction(rawValue: scrollUpRaw) {
            scrollUpAction = scrollUp
        } else {
            scrollUpAction = .hideOthers
        }

        var scrollDownAction: DockAction
        if let scrollDownRaw = userDefaults.string(forKey: scrollDownActionKey),
           let scrollDown = DockAction(rawValue: scrollDownRaw) {
            scrollDownAction = scrollDown
        } else {
            scrollDownAction = .hideApp
        }

        // One-time migration to move older defaults to current defaults.
        let migrated = userDefaults.bool(forKey: scrollDefaultsMigratedKey)
        if !migrated {
            // Legacy v1: minimizeAll up / appExpose down
            if scrollUpAction == .minimizeAll && scrollDownAction == .appExpose {
                scrollUpAction = .hideOthers
                scrollDownAction = .appExpose
                userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            // v2 default: appExpose up / minimizeAll down
            if scrollUpAction == .appExpose && scrollDownAction == .minimizeAll {
                scrollUpAction = .hideOthers
                scrollDownAction = .appExpose
                userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            userDefaults.set(true, forKey: scrollDefaultsMigratedKey)
        }

        // One-time migration to move prior default behavior to current defaults.
        let behaviorMigrated = userDefaults.bool(forKey: behaviorDefaultsMigratedKey)
        if !behaviorMigrated {
            let looksLikeLegacyDefaults = clickAction == .hideApp
                && scrollUpAction == .hideOthers
                && scrollDownAction == .appExpose

            if looksLikeLegacyDefaults {
                clickAction = .appExpose
                scrollDownAction = .hideApp
                userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            userDefaults.set(true, forKey: behaviorDefaultsMigratedKey)
        }

        // Extended modifier mappings.
        var shiftClickAction = Self.loadAction(from: userDefaults, forKey: shiftClickActionKey) ?? .none
        var optionClickAction = Self.loadAction(from: userDefaults, forKey: optionClickActionKey) ?? .singleAppMode
        var shiftOptionClickAction = Self.loadAction(from: userDefaults, forKey: shiftOptionClickActionKey) ?? .none

        var firstClickShiftAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftActionKey) ?? .hideOthers
        var firstClickOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickOptionActionKey) ?? .singleAppMode
        var firstClickShiftOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftOptionActionKey) ?? .none

        var shiftScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftScrollUpActionKey) ?? .none
        var optionScrollUpAction = Self.loadAction(from: userDefaults, forKey: optionScrollUpActionKey) ?? .none
        var shiftOptionScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollUpActionKey) ?? .none

        var shiftScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftScrollDownActionKey) ?? .none
        var optionScrollDownAction = Self.loadAction(from: userDefaults, forKey: optionScrollDownActionKey) ?? .none
        var shiftOptionScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollDownActionKey) ?? .none
        let folderClickAction = Self.loadFolderAction(from: userDefaults, forKey: folderClickActionKey) ?? DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        let shiftFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderClickActionKey) ?? .none
        let optionFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderClickActionKey) ?? .none
        let shiftOptionFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderClickActionKey) ?? .none
        let folderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: folderScrollUpActionKey) ?? DockFolderAction(
            openInApplicationIdentifier: "com.apple.Terminal",
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        let shiftFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderScrollUpActionKey) ?? .none
        let optionFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderScrollUpActionKey) ?? .none
        let shiftOptionFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderScrollUpActionKey) ?? .none
        let folderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: folderScrollDownActionKey) ?? DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        let shiftFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderScrollDownActionKey) ?? .none
        let optionFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderScrollDownActionKey) ?? .none
        let shiftOptionFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderScrollDownActionKey) ?? .none

        let modifierMigrated = userDefaults.bool(forKey: modifierDefaultsMigratedKey)
        if !modifierMigrated {
            // Respect explicit values when present, otherwise seed new keys.
            if userDefaults.object(forKey: shiftClickActionKey) == nil {
                shiftClickAction = .none
            }
            if userDefaults.object(forKey: optionClickActionKey) == nil {
                optionClickAction = .singleAppMode
            }
            if userDefaults.object(forKey: shiftOptionClickActionKey) == nil {
                shiftOptionClickAction = .none
            }

            if userDefaults.object(forKey: shiftScrollUpActionKey) == nil {
                shiftScrollUpAction = .none
            }
            if userDefaults.object(forKey: optionScrollUpActionKey) == nil {
                optionScrollUpAction = .none
            }
            if userDefaults.object(forKey: shiftOptionScrollUpActionKey) == nil {
                shiftOptionScrollUpAction = .none
            }

            if userDefaults.object(forKey: shiftScrollDownActionKey) == nil {
                shiftScrollDownAction = .none
            }
            if userDefaults.object(forKey: optionScrollDownActionKey) == nil {
                optionScrollDownAction = .none
            }
            if userDefaults.object(forKey: shiftOptionScrollDownActionKey) == nil {
                shiftOptionScrollDownAction = .none
            }

            userDefaults.set(true, forKey: modifierDefaultsMigratedKey)
        }

        let firstClickModifierMigrated = userDefaults.bool(forKey: firstClickModifierActionsMigratedKey)
        if !firstClickModifierMigrated {
            firstClickShiftAction = shiftClickAction
            firstClickOptionAction = optionClickAction
            firstClickShiftOptionAction = shiftOptionClickAction

            shiftClickAction = .none
            optionClickAction = .none
            shiftOptionClickAction = .none

            userDefaults.set(firstClickShiftAction.rawValue, forKey: firstClickShiftActionKey)
            userDefaults.set(firstClickOptionAction.rawValue, forKey: firstClickOptionActionKey)
            userDefaults.set(firstClickShiftOptionAction.rawValue, forKey: firstClickShiftOptionActionKey)
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
            userDefaults.set(true, forKey: firstClickModifierActionsMigratedKey)
        }

        Self.seedIfMissing(shiftClickAction, in: userDefaults, forKey: shiftClickActionKey)
        Self.seedIfMissing(optionClickAction, in: userDefaults, forKey: optionClickActionKey)
        Self.seedIfMissing(shiftOptionClickAction, in: userDefaults, forKey: shiftOptionClickActionKey)
        Self.seedIfMissing(firstClickShiftAction, in: userDefaults, forKey: firstClickShiftActionKey)
        Self.seedIfMissing(firstClickOptionAction, in: userDefaults, forKey: firstClickOptionActionKey)
        Self.seedIfMissing(firstClickShiftOptionAction, in: userDefaults, forKey: firstClickShiftOptionActionKey)
        Self.seedIfMissing(shiftScrollUpAction, in: userDefaults, forKey: shiftScrollUpActionKey)
        Self.seedIfMissing(optionScrollUpAction, in: userDefaults, forKey: optionScrollUpActionKey)
        Self.seedIfMissing(shiftOptionScrollUpAction, in: userDefaults, forKey: shiftOptionScrollUpActionKey)
        Self.seedIfMissing(shiftScrollDownAction, in: userDefaults, forKey: shiftScrollDownActionKey)
        Self.seedIfMissing(optionScrollDownAction, in: userDefaults, forKey: optionScrollDownActionKey)
        Self.seedIfMissing(shiftOptionScrollDownAction, in: userDefaults, forKey: shiftOptionScrollDownActionKey)
        Self.seedIfMissing(folderClickAction, in: userDefaults, forKey: folderClickActionKey)
        Self.seedIfMissing(shiftFolderClickAction, in: userDefaults, forKey: shiftFolderClickActionKey)
        Self.seedIfMissing(optionFolderClickAction, in: userDefaults, forKey: optionFolderClickActionKey)
        Self.seedIfMissing(shiftOptionFolderClickAction, in: userDefaults, forKey: shiftOptionFolderClickActionKey)
        Self.seedIfMissing(folderScrollUpAction, in: userDefaults, forKey: folderScrollUpActionKey)
        Self.seedIfMissing(shiftFolderScrollUpAction, in: userDefaults, forKey: shiftFolderScrollUpActionKey)
        Self.seedIfMissing(optionFolderScrollUpAction, in: userDefaults, forKey: optionFolderScrollUpActionKey)
        Self.seedIfMissing(shiftOptionFolderScrollUpAction, in: userDefaults, forKey: shiftOptionFolderScrollUpActionKey)
        Self.seedIfMissing(folderScrollDownAction, in: userDefaults, forKey: folderScrollDownActionKey)
        Self.seedIfMissing(shiftFolderScrollDownAction, in: userDefaults, forKey: shiftFolderScrollDownActionKey)
        Self.seedIfMissing(optionFolderScrollDownAction, in: userDefaults, forKey: optionFolderScrollDownActionKey)
        Self.seedIfMissing(shiftOptionFolderScrollDownAction, in: userDefaults, forKey: shiftOptionFolderScrollDownActionKey)

        // General settings defaults
        let showOnStartup = settingsStore.value(for: Self.showOnStartupPreferenceKey)
        let showMenuBarIcon = settingsStore.value(for: Self.showMenuBarIconPreferenceKey)
        let firstLaunchCompleted = settingsStore.value(for: Self.firstLaunchCompletedPreferenceKey)

        // Login item: prefer system status; fall back to stored preference
        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        let startAtLogin: Bool
        if loginItemEnabled {
            startAtLogin = true
        } else {
            startAtLogin = userDefaults.object(forKey: startAtLoginKey) as? Bool ?? false
        }

        let updateCheckFrequency = settingsStore.value(for: Self.updateCheckFrequencyPreferenceKey)

        let firstClickBehavior = settingsStore.value(for: Self.firstClickBehaviorPreferenceKey)

        let firstClickAppExposeRequiresMultipleWindows = userDefaults.object(forKey: firstClickAppExposeRequiresMultipleWindowsKey) as? Bool ?? true
        let clickAppExposeRequiresMultipleWindows = userDefaults.object(forKey: clickAppExposeRequiresMultipleWindowsKey) as? Bool ?? false
        var appExposeRequiresMultipleWindowsMap = userDefaults.object(forKey: appExposeRequiresMultipleWindowsMapKey) as? [String: Bool] ?? [:]

        let appExposeMapMigrated = userDefaults.bool(forKey: appExposeRequiresMultipleWindowsMapMigratedKey)
        if !appExposeMapMigrated {
            Self.seedMissingAppExposeGateSlots(in: &appExposeRequiresMultipleWindowsMap,
                                               firstClickDefault: firstClickAppExposeRequiresMultipleWindows,
                                               activeAppDefault: clickAppExposeRequiresMultipleWindows)
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
            userDefaults.set(true, forKey: appExposeRequiresMultipleWindowsMapMigratedKey)
        }

        // Assign stored properties last
        self.clickAction = clickAction
        self.firstClickBehavior = firstClickBehavior
        self.firstClickAppExposeRequiresMultipleWindows = firstClickAppExposeRequiresMultipleWindows
        self.clickAppExposeRequiresMultipleWindows = clickAppExposeRequiresMultipleWindows
        self.appExposeRequiresMultipleWindowsMap = appExposeRequiresMultipleWindowsMap
        self.firstClickShiftAction = firstClickShiftAction
        self.firstClickOptionAction = firstClickOptionAction
        self.firstClickShiftOptionAction = firstClickShiftOptionAction
        self.shiftClickAction = shiftClickAction
        self.optionClickAction = optionClickAction
        self.shiftOptionClickAction = shiftOptionClickAction
        self.folderClickAction = folderClickAction
        self.shiftFolderClickAction = shiftFolderClickAction
        self.optionFolderClickAction = optionFolderClickAction
        self.shiftOptionFolderClickAction = shiftOptionFolderClickAction
        self.scrollUpAction = scrollUpAction
        self.shiftScrollUpAction = shiftScrollUpAction
        self.optionScrollUpAction = optionScrollUpAction
        self.shiftOptionScrollUpAction = shiftOptionScrollUpAction
        self.folderScrollUpAction = folderScrollUpAction
        self.shiftFolderScrollUpAction = shiftFolderScrollUpAction
        self.optionFolderScrollUpAction = optionFolderScrollUpAction
        self.shiftOptionFolderScrollUpAction = shiftOptionFolderScrollUpAction
        self.scrollDownAction = scrollDownAction
        self.shiftScrollDownAction = shiftScrollDownAction
        self.optionScrollDownAction = optionScrollDownAction
        self.shiftOptionScrollDownAction = shiftOptionScrollDownAction
        self.folderScrollDownAction = folderScrollDownAction
        self.shiftFolderScrollDownAction = shiftFolderScrollDownAction
        self.optionFolderScrollDownAction = optionFolderScrollDownAction
        self.shiftOptionFolderScrollDownAction = shiftOptionFolderScrollDownAction
        self.showOnStartup = showOnStartup
        self.showMenuBarIcon = showMenuBarIcon
        self.firstLaunchCompleted = firstLaunchCompleted
        self.startAtLogin = startAtLogin
        self.updateCheckFrequency = updateCheckFrequency
    }

    private static func loadAction(from defaults: UserDefaults, forKey key: String) -> DockAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return DockAction(rawValue: raw)
    }

    private static func loadFolderAction(from defaults: UserDefaults, forKey key: String) -> DockFolderAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return DockFolderAction(storageValue: raw)
    }

    private static func seedIfMissing(_ action: DockAction, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(action.rawValue, forKey: key)
    }

    private static func seedIfMissing(_ action: DockFolderAction, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(action.storageValue, forKey: key)
    }

    private static func seedMissingAppExposeGateSlots(in map: inout [String: Bool],
                                                      firstClickDefault: Bool,
                                                      activeAppDefault: Bool) {
        let firstClickModifiers: [AppExposeSlotModifier] = [.shift, .option, .shiftOption]
        let clickModifiers: [AppExposeSlotModifier] = [.shift, .option, .shiftOption]
        let scrollSources: [AppExposeSlotSource] = [.scrollUp, .scrollDown]
        let scrollModifiers: [AppExposeSlotModifier] = [.none, .shift, .option, .shiftOption]

        for modifier in firstClickModifiers {
            let slot = AppExposeSlotKey.make(source: .firstClick, modifier: modifier)
            if map[slot] == nil {
                map[slot] = firstClickDefault
            }
        }

        for modifier in clickModifiers {
            let slot = AppExposeSlotKey.make(source: .click, modifier: modifier)
            if map[slot] == nil {
                map[slot] = activeAppDefault
            }
        }

        for source in scrollSources {
            for modifier in scrollModifiers {
                let slot = AppExposeSlotKey.make(source: source, modifier: modifier)
                if map[slot] == nil {
                    map[slot] = activeAppDefault
                }
            }
        }
    }

    func resetMappingsToDefaults() {
        resetAppActionsToDefaults()
        resetFolderActionsToDefaults()
    }

    func resetAppActionsToDefaults() {
        clickAction = .appExpose
        firstClickBehavior = .activateApp
        firstClickAppExposeRequiresMultipleWindows = true
        clickAppExposeRequiresMultipleWindows = false
        appExposeRequiresMultipleWindowsMap = [:]

        firstClickShiftAction = .hideOthers
        firstClickOptionAction = .singleAppMode
        firstClickShiftOptionAction = .none

        shiftClickAction = .none
        optionClickAction = .none
        shiftOptionClickAction = .none

        scrollUpAction = .hideOthers
        shiftScrollUpAction = .none
        optionScrollUpAction = .none
        shiftOptionScrollUpAction = .none

        scrollDownAction = .hideApp
        shiftScrollDownAction = .none
        optionScrollDownAction = .none
        shiftOptionScrollDownAction = .none
    }

    func resetFolderActionsToDefaults() {
        folderClickAction = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        shiftFolderClickAction = .none
        optionFolderClickAction = .none
        shiftOptionFolderClickAction = .none

        folderScrollUpAction = DockFolderAction(
            openInApplicationIdentifier: "com.apple.Terminal",
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        shiftFolderScrollUpAction = .none
        optionFolderScrollUpAction = .none
        shiftOptionFolderScrollUpAction = .none

        folderScrollDownAction = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        shiftFolderScrollDownAction = .none
        optionFolderScrollDownAction = .none
        shiftOptionFolderScrollDownAction = .none
    }

    func markUpdateCheckNow(_ date: Date = Date()) {
        settingsStore.set(date.timeIntervalSince1970, for: Self.lastUpdateCheckTimestampPreferenceKey)
    }

    func shouldCheckForUpdatesOnLaunch(now: Date = Date()) -> Bool {
        switch updateCheckFrequency {
        case .never:
            return false
        case .startup:
            return true
        case .hourly, .sixHours, .twelveHours, .daily, .weekly:
            guard let interval = updateCheckFrequency.interval else { return false }
            guard let lastCheck = lastUpdateCheckDate() else { return true }
            return now.timeIntervalSince(lastCheck) >= interval
        }
    }

    private func lastUpdateCheckDate() -> Date? {
        let timestamp = settingsStore.value(for: Self.lastUpdateCheckTimestampPreferenceKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

}
