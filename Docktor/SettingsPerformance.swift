import Foundation

enum SettingsPerformance {
    enum Event {
        case settingsOpen
        case paneSwitch
        case folderOptionsWarm

        fileprivate var startLabel: String {
            switch self {
            case .settingsOpen:
                return "settings_open_start"
            case .paneSwitch:
                return "pane_switch_start"
            case .folderOptionsWarm:
                return "folder_options_warm_start"
            }
        }

        fileprivate var endLabel: String {
            switch self {
            case .settingsOpen:
                return "settings_open_end"
            case .paneSwitch:
                return "pane_content_ready"
            case .folderOptionsWarm:
                return "folder_options_warm_end"
            }
        }
    }

    final class Session {
        private let event: Event
        private let metadata: [String: String]
        private let startedAt: ContinuousClock.Instant
        private var completed = false

        fileprivate init(event: Event, metadata: [String: String]) {
            self.event = event
            self.metadata = metadata
            self.startedAt = ContinuousClock().now
            SettingsPerformance.emit(event.startLabel, metadata: metadata)
        }

        func complete(extraMetadata: [String: String] = [:]) {
            guard completed == false else { return }
            completed = true

            var payload = metadata
            payload.merge(extraMetadata) { _, new in new }
            let elapsed = startedAt.duration(to: ContinuousClock().now)
            let durationMilliseconds = Int((Double(elapsed.components.seconds) * 1_000) +
                                           (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000))
            payload["duration_ms"] = "\(max(durationMilliseconds, 0))"
            SettingsPerformance.emit(event.endLabel, metadata: payload)
        }
    }

    private static let enabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["DOCKTOR_TEST_SUITE"] == "1" {
            return true
        }

        let perfFlag = environment["DOCKTOR_SETTINGS_PERF"]?.lowercased()
        return perfFlag == "1" || perfFlag == "true" || perfFlag == "yes"
    }()

    static func begin(_ event: Event, metadata: [String: String] = [:]) -> Session? {
        guard enabled else { return nil }
        return Session(event: event, metadata: metadata)
    }

    static func emit(_ label: String, metadata: [String: String] = [:]) {
        guard enabled else { return }

        let suffix = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: " ", with: "_"))" }
            .joined(separator: " ")
        if suffix.isEmpty {
            Logger.log("PERF \(label)")
        } else {
            Logger.log("PERF \(label) \(suffix)")
        }
    }
}
