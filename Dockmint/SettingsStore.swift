import Foundation

struct PreferenceKey<Value> {
    let name: String
    let defaultValue: Value
}

final class SettingsStore {
    static var currentDefaultsDomainName: String {
        defaultsDomainName(for: AppIdentity.bundleIdentifier)
    }

    static func defaultsDomainName(for bundleIdentifier: String) -> String {
        AppIdentity.defaultsDomainName(bundleIdentifier: bundleIdentifier)
    }

    let defaultsDomainName: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         defaultsDomainName: String = SettingsStore.currentDefaultsDomainName) {
        self.defaults = defaults
        self.defaultsDomainName = defaultsDomainName
    }

    func value(for key: PreferenceKey<Bool>) -> Bool {
        defaults.object(forKey: key.name) as? Bool ?? key.defaultValue
    }

    func set(_ value: Bool, for key: PreferenceKey<Bool>) {
        defaults.set(value, forKey: key.name)
    }

    func value(for key: PreferenceKey<Double>) -> Double {
        defaults.object(forKey: key.name) as? Double ?? key.defaultValue
    }

    func set(_ value: Double, for key: PreferenceKey<Double>) {
        defaults.set(value, forKey: key.name)
    }

    func value<T: RawRepresentable>(for key: PreferenceKey<T>) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key.name),
              let value = T(rawValue: raw) else {
            return key.defaultValue
        }
        return value
    }

    func set<T: RawRepresentable>(_ value: T, for key: PreferenceKey<T>) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key.name)
    }
}
