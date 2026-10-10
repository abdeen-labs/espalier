// Ported from desktop/app/src/lib/generic-git-auth.ts and lib/auth.ts

import EspalierSupport
import Foundation

/// Get the auth key for the endpoint: the keychain service under which
/// credentials for it are stored.
public func getKeyForEndpoint(_ endpoint: String) -> String {
    "Espalier - \(endpoint)"
}

/// Usernames and passwords for git hosts that aren't GitHub hosts. The
/// username for an endpoint is a setting; the password is in the keychain.
public struct GenericGitAuth: Sendable {
    public static let genericGitAuthUsernameKeyPrefix = "genericGitAuth/username/"

    let secrets: any SecretStore
    private let storage: SendableDefaults

    public init(secrets: any SecretStore, defaults: UserDefaults) {
        self.secrets = secrets
        storage = SendableDefaults(defaults)
    }

    private var defaults: UserDefaults { storage.defaults }

    private func getKeyForUsername(_ endpoint: String) -> String {
        "\(Self.genericGitAuthUsernameKeyPrefix)\(endpoint)"
    }

    /// Get the username for the host.
    public func getGenericUsername(_ endpoint: String) -> String? {
        defaults.string(forKey: getKeyForUsername(endpoint))
    }

    /// Set the username for the host.
    public func setGenericUsername(_ endpoint: String, _ username: String) {
        defaults.set(username, forKey: getKeyForUsername(endpoint))
    }

    /// Set the password for the username and host.
    public func setGenericPassword(_ endpoint: String, _ username: String, _ password: String) throws {
        try secrets.setSecret(password, service: getKeyForEndpoint(endpoint), account: username)
    }

    public func setGenericCredential(_ endpoint: String, _ username: String, _ password: String) throws {
        setGenericUsername(endpoint, username)
        try setGenericPassword(endpoint, username, password)
    }

    /// Get the password for the given username and host.
    public func getGenericPassword(_ endpoint: String, _ username: String) throws -> String? {
        try secrets.secret(service: getKeyForEndpoint(endpoint), account: username)
    }

    /// Delete a generic credential
    public func deleteGenericCredential(_ endpoint: String, _ username: String) throws {
        defaults.removeObject(forKey: getKeyForUsername(endpoint))
        try secrets.deleteSecret(service: getKeyForEndpoint(endpoint), account: username)
    }
}
