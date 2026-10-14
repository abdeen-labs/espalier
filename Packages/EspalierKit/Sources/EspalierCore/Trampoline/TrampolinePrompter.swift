// Ported from desktop/app/src/lib/trampoline/trampoline-ui-helper.ts

import GitKit

/// The user's answer to a prompt for an SSH key passphrase or password.
public struct PromptSSHSecretResponse: Sendable, Equatable {
    /// The secret, or `nil` when the user cancelled.
    public let secret: String?

    /// Whether the user asked to remember the secret. Espalier stores it in
    /// the keychain once the git operation succeeds.
    public let storeSecret: Bool

    public init(secret: String?, storeSecret: Bool) {
        self.secret = secret
        self.storeSecret = storeSecret
    }
}

/// The prompts git's callbacks need from the user. The app implements this
/// protocol with its sheets, and tests with a double.
///
/// Every prompt waits for the user's answer. When the git operation that
/// asked ends first, the waiting task is cancelled, and the prompt should
/// close and return its "cancelled" answer.
@MainActor
public protocol TrampolinePrompter: Sendable {
    /// ssh doesn't know the host's key: add it to `known_hosts` and connect?
    func promptAddingSSHHost(host: String, ip: String, keyType: String, fingerprint: String) async -> Bool

    /// The passphrase for the SSH key at `keyPath`, offering to remember it
    /// when `canRemember` (the key file can be read to identify it).
    func promptSSHKeyPassphrase(keyPath: String, canRemember: Bool) async -> PromptSSHSecretResponse

    /// The password for `username` (`user@host`).
    func promptSSHUserPassword(username: String) async -> PromptSSHSecretResponse

    /// A username and password (or token) for a host that isn't a GitHub
    /// host. Returns `nil` when the user dismisses it.
    ///
    /// - Parameters:
    ///   - endpoint: The remote, as a URL.
    ///   - username: The username from the remote URL, if it has one.
    func promptForGenericGitAuthentication(endpoint: String, username: String?) async -> TrampolineAccount?

    /// Signing in to the GitHub host at `endpoint` (github.com or an
    /// enterprise host) is needed. Returns the new account, or `nil` if the
    /// user cancelled or sign-in failed.
    func promptForGitHubSignIn(endpoint: String) async -> TrampolineAccount?

    /// A hook failed: abort the operation or ignore the failure? Used when
    /// the operation passes no `onHookFailure` of its own and isn't a
    /// background task.
    func promptHookFailure(hookName: String, terminalOutput: String) async -> HookFailureResolution
}
