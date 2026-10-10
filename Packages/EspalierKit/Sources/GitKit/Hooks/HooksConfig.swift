// Ported from desktop/app/src/lib/hooks/config.ts

import Foundation

/// Whether the hooks environment is on when the user hasn't chosen.
public let defaultHooksEnvEnabledValue = true

/// Whether the hooks environment is enabled: hooks run through the hooks
/// proxy, in the user's login shell environment.
public func getHooksEnvEnabled(defaults: UserDefaults = .standard) -> Bool {
    getBoolean(defaults, hooksEnvEnabledKey, defaultHooksEnvEnabledValue)
}

public func setHooksEnvEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: hooksEnvEnabledKey)
}

public let defaultCacheHooksEnvValue = true

/// Whether to keep the shell environment for later operations. When off, it
/// is loaded again for each operation (a commit, a merge) that runs hooks.
public func getCacheHooksEnv(defaults: UserDefaults = .standard) -> Bool {
    getBoolean(defaults, cacheHooksEnvKey, defaultCacheHooksEnvValue)
}

public func setCacheHooksEnv(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: cacheHooksEnvKey)
}

// `UserDefaults` keys.
private let hooksEnvEnabledKey = "git-hooks-env-enabled"
private let cacheHooksEnvKey = "git-cache-hooks-env"

/// Reads a Boolean from `UserDefaults`: a stored Boolean, or one of the
/// strings "1", "true", "0", and "false". Anything else gives
/// `defaultValue`.
private func getBoolean(_ defaults: UserDefaults, _ key: String, _ defaultValue: Bool) -> Bool {
    let value = defaults.object(forKey: key)
    if let value = value as? Bool {
        return value
    }
    switch value as? String {
    case "1", "true": return true
    case "0", "false": return false
    default: return defaultValue
    }
}
