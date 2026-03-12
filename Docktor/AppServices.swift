import Foundation

@MainActor
final class AppServices {
    static let live = AppServices(
        preferences: Preferences.shared,
        coordinator: DockExposeCoordinator.shared,
        updateManager: UpdateManager.shared,
        folderOpenWithOptionsStore: FolderOpenWithOptionsStore()
    )

    let preferences: Preferences
    let coordinator: DockExposeCoordinator
    let updateManager: UpdateManager
    let folderOpenWithOptionsStore: FolderOpenWithOptionsStore

    static var appDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }
        return "Docktor"
    }

    static var settingsWindowTitle: String {
        "\(appDisplayName) Settings"
    }

    init(preferences: Preferences,
         coordinator: DockExposeCoordinator,
         updateManager: UpdateManager,
         folderOpenWithOptionsStore: FolderOpenWithOptionsStore) {
        self.preferences = preferences
        self.coordinator = coordinator
        self.updateManager = updateManager
        self.folderOpenWithOptionsStore = folderOpenWithOptionsStore
    }
}
