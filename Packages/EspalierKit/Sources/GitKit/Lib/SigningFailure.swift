// Reads git's output when a commit or tag can't be signed, to say what went
// wrong (`DugiteError` recognizes only GPG's "gpg failed to sign the data",
// and nothing for SSH).

import Foundation

/// Why git couldn't sign a commit or a tag (`commit.gpgsign`,
/// `tag.gpgsign`), read from its output.
public enum SigningFailure: Sendable, Equatable {
    /// Git couldn't run the signing program: gpg, gpgsm (`gpg.format`
    /// x509), ssh-keygen (ssh), or the one the configuration names.
    case programNotFound(program: String)
    /// GPG needed the key's passphrase, but its pinentry program only works
    /// in a terminal (pinentry-curses, pinentry-tty), and git has none.
    case pinentryNeedsTerminal(pinentry: String)
    /// GPG couldn't start its pinentry program at all.
    case pinentryUnavailable
    /// The user closed the passphrase prompt.
    case cancelled
    /// The key's passphrase was wrong (or none was given).
    case badPassphrase
    /// GPG has no secret key (gpgsm no certificate) for `key`, the
    /// configured `user.signingkey` or else the committer's identity.
    case noSecretKey(key: String)
    /// GPG's key for `key` has expired or has been revoked.
    case unusableKey(key: String)
    /// GPG couldn't start or reach gpg-agent.
    case noAgent
    /// SSH signing is on, but no key is configured to sign with.
    case sshKeyNotConfigured
    /// The SSH key to sign with is only in an agent (`key::` in
    /// `user.signingkey`), and there's no agent to ask.
    case sshAgentUnavailable
    /// The SSH agent doesn't have the key to sign with.
    case sshKeyNotInAgent
    /// The public key at `path` has no private key next to it, and no agent
    /// has it.
    case sshPrivateKeyNotFound(path: String)
    /// The key file `user.signingkey` names doesn't exist.
    case sshKeyNotFound(path: String)
    /// Signing failed for another reason; git's output says why.
    case other
}

/// Reads why git couldn't sign a commit or tag from its standard error, or
/// returns nil when it isn't a signing failure.
public func parseSigningFailure(_ stderr: String) -> SigningFailure? {
    // GPG and gpgsm (git runs both the same way, with --status-fd=2).
    if stderr.contains("gpg failed to sign the data") {
        return parseGPGFailure(stderr)
    }

    // SSH: ssh-keygen's error, then git's.
    if stderr.contains("user.signingKey needs to be set for ssh signing")
        || stderr.contains("either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured") {
        return .sshKeyNotConfigured
    }
    guard stderr.contains("failed to write commit object") || stderr.contains("unable to sign the tag") else {
        return nil
    }
    if let program = firstCapture(stderr, cannotRunRe) ?? firstCapture(stderr, cannotExecRe) {
        return .programNotFound(program: program)
    }
    if stderr.contains("Couldn't get agent socket") {
        return .sshAgentUnavailable
    }
    if stderr.contains("Couldn't find key in agent") {
        return .sshKeyNotInAgent
    }
    if stderr.contains("incorrect passphrase supplied to decrypt private key") {
        return .badPassphrase
    }
    if let path = firstCapture(stderr, noPrivateKeyRe) {
        return .sshPrivateKeyNotFound(path: path)
    }
    if let path = firstCapture(stderr, cannotLoadPublicKeyRe) {
        return .sshKeyNotFound(path: path)
    }
    return nil
}

private func parseGPGFailure(_ stderr: String) -> SigningFailure {
    if let program = firstCapture(stderr, cannotRunRe) ?? firstCapture(stderr, cannotExecRe) {
        return .programNotFound(program: program)
    }
    // The pinentry GPG started, from its status line, before what it said:
    // pinentry-tty reports a missing terminal as a cancellation.
    if let flavor = firstCapture(stderr, pinentryLaunchedRe), ["curses", "tty"].contains(flavor) {
        return .pinentryNeedsTerminal(pinentry: "pinentry-\(flavor)")
    }
    if stderr.contains("No pinentry") {
        return .pinentryUnavailable
    }
    if stderr.contains("Operation cancelled") {
        return .cancelled
    }
    if stderr.contains("Bad passphrase") {
        return .badPassphrase
    }
    if let key = firstCapture(stderr, unusableKeyRe) {
        return .unusableKey(key: key)
    }
    if stderr.contains("No agent running") || stderr.contains("can't connect to the gpg-agent") || stderr.contains("can't connect to the agent") {
        return .noAgent
    }
    if let key = firstCapture(stderr, noSecretKeyRe) ?? firstCapture(stderr, gpgsmNoKeyRe) {
        return .noSecretKey(key: key)
    }
    if stderr.contains("No secret key") {
        return .noSecretKey(key: "")
    }
    return .other
}

// error: cannot run gpg: No such file or directory
nonisolated(unsafe) private let cannotRunRe = /error: cannot run ([^:\n]+): No such file or directory/
// A program named by its path: fatal: cannot exec '/opt/gpg': No such file or directory
nonisolated(unsafe) private let cannotExecRe = /cannot exec '([^'\n]+)': No such file or directory/
// [GNUPG:] PINENTRY_LAUNCHED 19687 curses 1.3.3 - - . - 501/20 0
nonisolated(unsafe) private let pinentryLaunchedRe = /\[GNUPG:\] PINENTRY_LAUNCHED \d+ (\S+)/
// gpg: skipped "DEADBEEF": No secret key
nonisolated(unsafe) private let noSecretKeyRe = /skipped "([^"\n]+)": No secret key/
// gpg: skipped "DEADBEEF": Unusable secret key
nonisolated(unsafe) private let unusableKeyRe = /skipped "([^"\n]+)": Unusable secret key/
// gpgsm: can't sign using 'DEADBEEF': No public key
nonisolated(unsafe) private let gpgsmNoKeyRe = /can't sign using '([^'\n]+)': No public key/
// error: No private key found for public key "/Users/joe/.ssh/id_ed25519.pub"?
nonisolated(unsafe) private let noPrivateKeyRe = /No private key found for public key "([^"\n]+)"/
// error: Couldn't load public key /Users/joe/.ssh/missing: No such file or directory?
nonisolated(unsafe) private let cannotLoadPublicKeyRe = /Couldn't load public key ([^\n]+): No such file or directory/

private func firstCapture(_ text: String, _ regex: Regex<(Substring, Substring)>) -> String? {
    text.firstMatch(of: regex.matchingSemantics(.unicodeScalar)).map { String($0.output.1) }
}
