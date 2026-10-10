// Ported from desktop/app/src/lib/auth.ts

/// The application name that prefixes every keychain service name.
public let keychainServicePrefix = "Espalier"

/// Get the auth key for the user: the keychain service name its token is
/// stored under. The keychain account name is the user's login.
public func getKeyForAccount(_ account: Account) -> String {
    getKeyForEndpoint(account.endpoint)
}

/// Get the auth key for the endpoint, e.g. `Espalier - https://api.github.com`.
public func getKeyForEndpoint(_ endpoint: String) -> String {
    "\(keychainServicePrefix) - \(endpoint)"
}
