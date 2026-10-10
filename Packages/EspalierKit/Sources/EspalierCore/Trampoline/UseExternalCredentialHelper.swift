// Ported from desktop/app/src/lib/trampoline/use-external-credential-helper.ts

import Foundation

public let useExternalCredentialHelperDefault = false
public let useExternalCredentialHelperKey = "useExternalCredentialHelper"

/// Whether generic (non-GitHub) credentials come from Git Credential Manager
/// instead of Espalier's own prompt and keychain items.
public func useExternalCredentialHelper(defaults: UserDefaults = .standard) -> Bool {
    // A stored Boolean, or a Boolean stored as a string.
    let value = defaults.object(forKey: useExternalCredentialHelperKey)
    if let value = value as? Bool {
        return value
    }
    switch value as? String {
    case "1", "true": return true
    case "0", "false": return false
    default: return useExternalCredentialHelperDefault
    }
}

public func setUseExternalCredentialHelper(_ value: Bool, defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: useExternalCredentialHelperKey)
}
