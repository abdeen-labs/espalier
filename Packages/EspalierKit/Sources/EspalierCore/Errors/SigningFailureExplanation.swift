// When a commit or tag can't be signed, git's output is only "error: gpg
// failed to sign the data" and GPG's status lines. The error's presentation
// puts this explanation before that output.

import Foundation
import GitKit

extension SigningFailure {
    /// What went wrong and what to do about it, for signing a `noun`
    /// ("commit" or "tag").
    public func explanation(signing noun: String) -> String {
        switch self {
        case .programNotFound(let program):
            switch POSIXPathName(program) {
            case "gpg":
                return "Git couldn't find gpg, which signs your \(noun)s. Install GnuPG (for example, with Homebrew), or set gpg.program in your Git configuration to gpg's full path."
            case "gpgsm":
                return "Git couldn't find gpgsm, which signs your \(noun)s with your X.509 certificate. Install GnuPG, or set gpg.x509.program in your Git configuration to gpgsm's full path."
            default:
                return "Git couldn't run \(program), which signs your \(noun)s. Check that it's installed, and that your Git configuration names it by its full path."
            }
        case .pinentryNeedsTerminal(let pinentry):
            return "GPG needs your key's passphrase, but its passphrase prompt (\(pinentry)) only works in a terminal. Set a prompt that opens a window, such as pinentry-mac, as pinentry-program in gpg-agent.conf in your GnuPG folder (~/.gnupg), then run gpgconf --kill gpg-agent in Terminal."
        case .pinentryUnavailable:
            return "GPG couldn't start its passphrase prompt. Check pinentry-program in gpg-agent.conf in your GnuPG folder (~/.gnupg)."
        case .cancelled:
            return "The \(noun) wasn't signed because the passphrase prompt was closed."
        case .badPassphrase:
            return "The passphrase for your signing key was wrong, or none was entered."
        case .noSecretKey(let key) where key.isEmpty:
            return "GPG has no secret key to sign with. Set user.signingkey in your Git configuration to your key's ID."
        case .noSecretKey(let key):
            return "GPG has no secret key for \(key). Set user.signingkey in your Git configuration to the ID of the key you sign with, or import that key into GPG."
        case .unusableKey(let key):
            return "GPG can't sign with \(key): the key has expired or has been revoked. Renew it, or set user.signingkey in your Git configuration to another key."
        case .noAgent:
            return "GPG couldn't reach gpg-agent, which keeps your secret keys. Run gpgconf --launch gpg-agent in Terminal to see why it doesn't start."
        case .sshKeyNotConfigured:
            return "Signing with SSH is on, but no key is set to sign with. Set user.signingkey in your Git configuration to your public key's path."
        case .sshAgentUnavailable:
            return "Your signing key is set as a key in your SSH agent, but Espalier can't reach an agent. Make sure the agent runs and your shell sets SSH_AUTH_SOCK, or set user.signingkey to the key's file."
        case .sshKeyNotInAgent:
            return "Your SSH agent doesn't have your signing key. Add it with ssh-add, or set user.signingkey to the key's file."
        case .sshPrivateKeyNotFound(let path):
            return "Git couldn't find the private key for \(path): your SSH agent doesn't have it, and it isn't next to the public key."
        case .sshKeyNotFound(let path):
            return "Git couldn't find \(path), the SSH key user.signingkey names."
        case .other:
            return "Git couldn't sign the \(noun)."
        }
    }
}

/// The last component of a path, or the name itself.
private func POSIXPathName(_ program: String) -> String {
    program.split(separator: "/").last.map(String.init) ?? program
}

extension OperationError {
    /// Why git couldn't sign a commit or tag, when that's why the operation
    /// failed.
    public var signingFailure: SigningFailure? {
        gitFailure.flatMap { parseSigningFailure($0.stderr) }
    }

    /// The explanation of `signingFailure`, which the error's presentation
    /// shows before git's output.
    public var signingFailureExplanation: String? {
        signingFailure?.explanation(signing: operation == .createTag ? "tag" : "commit")
    }
}
