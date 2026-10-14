// Ported from desktop/app/src/lib/ssh/ssh-credential-storage.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "trampoline")

private let appName = "Espalier"

/// The keychain service for a kind of SSH credential.
func getSSHCredentialStoreKey(_ name: String) -> String {
    "\(appName) - \(name)"
}

/// The SSH credential the current git operation used most recently.
struct SSHCredentialEntry: Sendable, Equatable {
    /// Store where this entry is stored.
    let store: String

    /// Key used to identify the credential in the store (e.g. username or
    /// hash).
    let key: String

    /// A secret the user just entered and asked to remember, which is stored
    /// once the operation succeeds. `nil` for a secret read from the store.
    let pendingSecret: String?
}

// A secret the user asked to remember stays pending in the operation's
// state and is stored only when the operation succeeds. Written to the
// keychain right away, a mistyped passphrase would answer ssh's next
// prompt, so the user couldn't correct it within the same operation.

/// Keeps the SSH credential in memory, to store it if the ongoing git
/// operation succeeds.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - store: Store where the SSH credential is stored.
///   - key: Key that identifies the SSH credential (e.g. username or key
///     hash).
///   - password: Password for the SSH key / user.
func setSSHCredential(_ invocation: TrampolineInvocation, _ store: String, _ key: String, _ password: String) {
    invocation.setMostRecentSSHCredential(SSHCredentialEntry(store: store, key: key, pendingSecret: password))
}

/// Keeps the details of the stored SSH credential just given, to be deleted
/// if ssh-keygen rejects it.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - store: Store where the SSH credential is stored.
///   - key: Key that identifies the SSH credential (e.g. username or key
///     hash).
func setMostRecentSSHCredential(_ invocation: TrampolineInvocation, _ store: String, _ key: String) {
    invocation.setMostRecentSSHCredential(SSHCredentialEntry(store: store, key: key, pendingSecret: nil))
}

/// Removes the SSH credential from memory. This must be used after a git
/// operation finished, regardless the result.
func removeMostRecentSSHCredential(_ invocation: TrampolineInvocation) {
    invocation.setMostRecentSSHCredential(nil)
}

/// Deletes the most recent SSH credential from the store. Used when
/// ssh-keygen rejects it.
func deleteMostRecentSSHCredential(_ invocation: TrampolineInvocation, _ secrets: any SecretStore) {
    guard let entry = invocation.mostRecentSSHCredential else { return }
    deleteSSHCredential(entry.store, entry.key, secrets)
}

/// Deletes a stored SSH credential that was rejected.
func deleteSSHCredential(_ store: String, _ key: String, _ secrets: any SecretStore) {
    logger.info("SSH credential rejected, deleting it from \(store, privacy: .public)")
    do {
        try secrets.deleteSecret(service: store, account: key)
    } catch {
        logger.error("Could not delete SSH credential: \(error.localizedDescription, privacy: .public)")
    }
}

/// Stores the SSH credential the user asked to remember during the git
/// operation, which just succeeded.
func storePendingSSHCredential(_ invocation: TrampolineInvocation, _ secrets: any SecretStore) {
    guard let entry = invocation.mostRecentSSHCredential, let secret = entry.pendingSecret else { return }
    do {
        try secrets.setSecret(secret, service: entry.store, account: entry.key)
    } catch {
        logger.error("Could not store SSH credential: \(error.localizedDescription, privacy: .public)")
    }
}
