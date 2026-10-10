// Ported from desktop/app/src/lib/ssh/ssh-user-password.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "trampoline")

let SSHUserPasswordTokenStoreKey = getSSHCredentialStoreKey("SSH user password")

/// Retrieves the password for the given SSH username.
func getSSHUserPassword(_ username: String, _ secrets: any SecretStore) -> String? {
    do {
        return try secrets.secret(service: SSHUserPasswordTokenStoreKey, account: username)
    } catch {
        logger.error("Could not retrieve passphrase for SSH key: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Keeps the SSH user password, to store it if the operation succeeds.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - username: SSH user name. Usually in the form of `user@hostname`.
///   - password: Password for the given user.
func setSSHUserPassword(_ invocation: TrampolineInvocation, _ username: String, _ password: String) {
    setSSHCredential(invocation, SSHUserPasswordTokenStoreKey, username, password)
}

/// Keeps the SSH credential details in memory to be deleted later if the
/// ongoing git operation fails to authenticate.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - username: SSH user name.
func setMostRecentSSHUserPassword(_ invocation: TrampolineInvocation, _ username: String) {
    setMostRecentSSHCredential(invocation, SSHUserPasswordTokenStoreKey, username)
}
