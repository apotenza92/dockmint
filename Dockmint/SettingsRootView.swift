import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences
    @ObservedObject var folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    let onPaneAppear: (SettingsPane) -> Void
    let onPaneSelectionRequest: (SettingsPane) -> Void

    var body: some View {
        Group {
            if preferences.shouldPresentOnboarding {
                OnboardingView(
                    coordinator: coordinator,
                    preferences: preferences
                )
            } else {
                PreferencesView(
                    coordinator: coordinator,
                    updateManager: updateManager,
                    preferences: preferences,
                    folderOpenWithOptionsStore: folderOpenWithOptionsStore,
                    viewModel: viewModel,
                    onPaneAppear: onPaneAppear,
                    onPaneSelectionRequest: onPaneSelectionRequest
                )
            }
        }
    }
}

struct SharedPermissionsSection: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    let buttonTitle: String
    let footerText: String?

    private let appDisplayName = AppServices.appDisplayName

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionStatusRow(
                permission: .accessibility,
                granted: coordinator.accessibilityGranted,
                infoText: "Allows \(appDisplayName) to identify Dock icons and trigger actions.",
                buttonTitle: buttonTitle,
                action: { coordinator.requestPermissionFromUser(.accessibility) }
            )

            PermissionStatusRow(
                permission: .inputMonitoring,
                granted: coordinator.inputMonitoringGranted,
                infoText: "Allows \(appDisplayName) to listen for global click and scroll gestures.",
                buttonTitle: buttonTitle,
                action: { coordinator.requestPermissionFromUser(.inputMonitoring) }
            )

            if let footerText {
                Text(footerText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionStatusRow: View {
    let permission: DockmintPermission
    let granted: Bool
    let infoText: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(granted ? Color.green : Color.orange)

                Text(permission.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(infoText)
            }

            Spacer(minLength: 0)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
