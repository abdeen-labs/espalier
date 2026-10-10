// Ported from desktop/app/src/lib/ssh/ssh-key-passphrase.ts and lib/get-file-hash.ts

import CryptoKit
import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "trampoline")

let SSHKeyPassphraseTokenStoreKey = getSSHCredentialStoreKey("SSH key passphrases")

/// The SHA-256 digest of the key file, in hexadecimal: the keychain account
/// its passphrase is stored under.
func getHashForSSHKey(_ keyPath: String) throws -> String {
    let contents = try Data(contentsOf: URL(filePath: keyPath))
    return SHA256.hash(data: contents).map { byte in
        let hex = String(byte, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
    }.joined()
}

/// Retrieves the passphrase for the SSH key in the given path.
func getSSHKeyPassphrase(_ keyPath: String, _ secrets: any SecretStore) -> String? {
    do {
        let fileHash = try getHashForSSHKey(keyPath)
        return try secrets.secret(service: SSHKeyPassphraseTokenStoreKey, account: fileHash)
    } catch {
        logger.error("Could not retrieve passphrase for SSH key: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Keeps the SSH key passphrase, to store it if the operation succeeds.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - keyPath: Path to the SSH key.
///   - passphrase: Passphrase for the SSH key.
func setSSHKeyPassphrase(_ invocation: TrampolineInvocation, _ keyPath: String, _ passphrase: String) {
    do {
        let keyHash = try getHashForSSHKey(keyPath)
        setSSHCredential(invocation, SSHKeyPassphraseTokenStoreKey, keyHash, passphrase)
    } catch {
        logger.error("Could not store passphrase for SSH key: \(error.localizedDescription, privacy: .public)")
    }
}

/// Keeps the SSH credential details in memory to be deleted later if the
/// ongoing git operation fails to authenticate.
///
/// - Parameters:
///   - invocation: The ongoing git operation.
///   - keyPath: Path of the SSH key.
func setMostRecentSSHKeyPassphrase(_ invocation: TrampolineInvocation, _ keyPath: String) {
    do {
        let keyHash = try getHashForSSHKey(keyPath)
        setMostRecentSSHCredential(invocation, SSHKeyPassphraseTokenStoreKey, keyHash)
    } catch {
        logger.error("Could not store passphrase for SSH key: \(error.localizedDescription, privacy: .public)")
    }
}
