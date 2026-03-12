import Combine
import Foundation

@MainActor
final class FolderOpenWithOptionsStore: ObservableObject {
    @Published private(set) var options: [DockFolderOpenApplicationOption]
    @Published private(set) var isReady = false

    private var warmTask: Task<Void, Never>?

    init() {
        options = DockFolderOpenApplicationCatalog.minimalOptions()
    }

    func warmIfNeeded() {
        guard warmTask == nil, isReady == false else { return }

        let session = SettingsPerformance.begin(.folderOptionsWarm)
        warmTask = Task { @MainActor [weak self] in
            guard let self else { return }

            DockFolderOpenApplicationCatalog.refreshOptionsCache()
            options = DockFolderOpenApplicationCatalog.options()
            isReady = true
            session?.complete(extraMetadata: ["count": "\(options.count)"])
            warmTask = nil
        }
    }

    func options(including selectedIdentifier: String?) -> [DockFolderOpenApplicationOption] {
        let normalizedSelectedIdentifier = DockFolderOpenApplicationCatalog.normalize(
            selectedIdentifier ?? DockFolderOpenApplicationCatalog.noneIdentifier
        )

        guard normalizedSelectedIdentifier != DockFolderOpenApplicationCatalog.noneIdentifier,
              options.contains(where: { $0.identifier == normalizedSelectedIdentifier }) == false else {
            return options
        }

        var resolvedOptions = options
        resolvedOptions.append(
            DockFolderOpenApplicationCatalog.placeholderOption(for: normalizedSelectedIdentifier)
        )
        return resolvedOptions
    }
}
