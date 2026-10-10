import Foundation
import GitHubKit

/// GitHubKit's `DataStore` over `UserDefaults`: the accounts list (`users`,
/// without tokens) and GitHub Enterprise Server versions
/// (`endpoint-version:<api>`) live beside the other settings.
public struct UserDefaultsDataStore: DataStore {
    private let defaults: SendableDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = SendableDefaults(defaults)
    }

    public func setItem(_ key: String, _ value: String) {
        defaults.defaults.set(value, forKey: key)
    }

    /// The string stored under `key`; nil when nothing, or something other
    /// than a string, is.
    public func getItem(_ key: String) -> String? {
        defaults.defaults.object(forKey: key) as? String
    }
}
