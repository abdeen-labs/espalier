// Ported from desktop/app/src/lib/trampoline/trampoline-askpass-handler.ts

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "trampoline")

/// GitHub's SSH host key fingerprints, as GitHub publishes them at
/// https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
///
/// These keys are accepted without asking; the user is asked about any
/// other. GitHub's retired RSA key,
/// `SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8`, isn't among them:
/// its private part was briefly exposed, so accepting it would let anyone
/// holding that key impersonate github.com.
private let gitHubHostKeyFingerprints: [String: String] = [
    "ED25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
    "ECDSA": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
    "RSA": "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
]

private let sshKeyPassphrasePromptRe = JSCompat.regex(#"^Enter passphrase for key '("# + JSCompat.dot + #"+)': \z"#)
// ssh-keygen's, when git has it sign a commit or tag with a key file
// (`gpg.format` ssh).
private let signingKeyPassphrasePromptRe = JSCompat.regex(#"^Enter passphrase for "("# + JSCompat.dot + #"+)": \z"#)
private let sshUserPasswordPromptRe = JSCompat.regex(#"^("# + JSCompat.dot + "+@" + JSCompat.dot + #"+)'s password: \z"#)

/// Answers ssh's prompts (espalier-askpass running as `SSH_ASKPASS`).
struct TrampolineAskpassHandler: Sendable {
    let invocation: TrampolineInvocation
    let prompter: any TrampolinePrompter
    let secrets: any SecretStore

    /// The answer to print, or `nil` to print nothing.
    func handle(_ command: TrampolineCommand) async -> String? {
        guard command.parameters.count == 1 else {
            return nil
        }

        let firstParameter = command.parameters[0]

        if JSCompat.startsWith(firstParameter, "The authenticity of host ") {
            return await handleSSHHostAuthenticity(firstParameter)
        }

        if JSCompat.startsWith(firstParameter, "Enter passphrase for key ") {
            return await handleSSHKeyPassphrase(firstParameter, from: command.parentProcessID)
        }

        if JSCompat.startsWith(firstParameter, "Enter passphrase for \"") {
            return await handleSigningKeyPassphrase(firstParameter)
        }

        if firstParameter.unicodeScalars.reversed().starts(with: "'s password: ".unicodeScalars.reversed()) {
            return await handleSSHUserPassword(firstParameter, from: command.parentProcessID)
        }

        return nil
    }

    private func handleSSHHostAuthenticity(_ prompt: String) async -> String? {
        guard let info = parseAddSSHHostPrompt(prompt) else {
            return nil
        }

        // We'll accept github.com as valid host automatically. GitHub's public
        // key fingerprint can be obtained from
        // https://docs.github.com/en/github/authenticating-to-github/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
        if info.host == "github.com", gitHubHostKeyFingerprints[info.keyType] == info.fingerprint {
            return "yes"
        }

        if invocation.isBackgroundTask {
            logger.debug("handleSSHHostAuthenticity: background task environment, skipping prompt")
            return nil
        }

        let addHost = await prompter.promptAddingSSHHost(
            host: info.host,
            ip: info.ip,
            keyType: info.keyType,
            fingerprint: info.fingerprint
        )
        return addHost ? "yes" : "no"
    }

    /// The stored secret `key` in `store` (read with `read`) to give
    /// `process`, or nil when none is stored or `process` was given it
    /// before. ssh asks again only when it rejected the answer, so then the
    /// stored secret is deleted and the user is asked instead.
    private func storedSecret(_ store: String, _ key: String, for process: pid_t?, read: () -> String?) -> String? {
        guard let stored = read() else {
            return nil
        }
        if invocation.recordStoredSSHSecret(store: store, key: key, givenTo: process) {
            return stored
        }
        deleteSSHCredential(store, key, secrets)
        return nil
    }

    private func handleSSHKeyPassphrase(_ prompt: String, from process: pid_t?) async -> String? {
        guard let matches = JSCompat.match(prompt, sshKeyPassphrasePromptRe), let keyPath = matches[1] else {
            return nil
        }

        // ssh truncates key paths longer than 100 bytes in this prompt, so the
        // passphrase of such a key can't be found or stored, and the prompt
        // doesn't offer to remember it.
        let keyHash = try? getHashForSSHKey(keyPath)

        if let keyHash,
           let storedPassphrase = storedSecret(SSHKeyPassphraseTokenStoreKey, keyHash, for: process, read: { getSSHKeyPassphrase(keyPath, secrets) })
        {
            return storedPassphrase
        }

        if invocation.isBackgroundTask {
            logger.debug("handleSSHKeyPassphrase: background task environment, skipping prompt")
            return nil
        }

        let response = await prompter.promptSSHKeyPassphrase(keyPath: keyPath, canRemember: keyHash != nil)

        // If the user wanted us to remember the passphrase, we'll keep it
        // around to store it later if the git operation succeeds. However,
        // when running a git command, it's possible that the user will need
        // to enter the passphrase multiple times if there are failed
        // attempts. Because of that, we need to remove any pending
        // passphrases to be stored when, in one of those multiple attempts,
        // the user chooses NOT to remember the passphrase.
        if let passphrase = response.secret, response.storeSecret {
            setSSHKeyPassphrase(invocation, keyPath, passphrase)
        } else {
            removeMostRecentSSHCredential(invocation)
        }

        return response.secret ?? ""
    }

    /// ssh-keygen asks for a key file's passphrase when git has it sign a
    /// commit or tag and no agent has the key. It's the same passphrase as
    /// ssh's, kept the same way (by the key file's hash), and asked for at
    /// most once per git command: a rebase or cherry-pick runs ssh-keygen
    /// once per commit.
    private func handleSigningKeyPassphrase(_ prompt: String) async -> String? {
        guard let matches = JSCompat.match(prompt, signingKeyPassphrasePromptRe), let keyPath = matches[1] else {
            return nil
        }

        if let entered = invocation.signingKeyPassphrase(keyPath) {
            return entered
        }

        if let storedPassphrase = getSSHKeyPassphrase(keyPath, secrets) {
            // Deleted if ssh-keygen rejects it.
            setMostRecentSSHKeyPassphrase(invocation, keyPath)
            return storedPassphrase
        }

        if invocation.isBackgroundTask {
            logger.debug("handleSigningKeyPassphrase: background task environment, skipping prompt")
            return nil
        }

        let response = await prompter.promptSSHKeyPassphrase(keyPath: keyPath, canRemember: (try? getHashForSSHKey(keyPath)) != nil)

        if let passphrase = response.secret, response.storeSecret {
            setSSHKeyPassphrase(invocation, keyPath, passphrase)
        } else {
            removeMostRecentSSHCredential(invocation)
        }
        if let passphrase = response.secret {
            invocation.setSigningKeyPassphrase(passphrase, for: keyPath)
        }

        return response.secret ?? ""
    }

    private func handleSSHUserPassword(_ prompt: String, from process: pid_t?) async -> String? {
        guard let matches = JSCompat.match(prompt, sshUserPasswordPromptRe), let username = matches[1] else {
            return nil
        }

        if let storedPassword = storedSecret(SSHUserPasswordTokenStoreKey, username, for: process, read: { getSSHUserPassword(username, secrets) }) {
            return storedPassword
        }

        if invocation.isBackgroundTask {
            logger.debug("handleSSHUserPassword: background task environment, skipping prompt")
            return nil
        }

        let response = await prompter.promptSSHUserPassword(username: username)

        if let password = response.secret, response.storeSecret {
            setSSHUserPassword(invocation, username, password)
        } else {
            removeMostRecentSSHCredential(invocation)
        }

        return response.secret ?? ""
    }
}
