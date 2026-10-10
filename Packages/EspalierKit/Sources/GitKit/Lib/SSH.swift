// Ported from desktop/app/src/lib/ssh/ssh.ts

import EspalierSupport
import Foundation

/// Returns the git environment variables related to SSH: ssh asks
/// espalier-askpass for host key confirmations, key passphrases, and
/// passwords.
///
/// ssh only uses `SSH_ASKPASS` when `DISPLAY` is set and there's no
/// terminal. `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4 and later) makes ssh
/// use `SSH_ASKPASS` whether or not it has a terminal. macOS 26 ships
/// OpenSSH 10. `DISPLAY` is for an older ssh the user may have configured
/// (`core.sshCommand`, `GIT_SSH_COMMAND`).
///
/// - Parameter askpassPath: The absolute path of espalier-askpass.
public func getSSHEnvironment(askpassPath: String) -> [String: String] {
    [
        "SSH_ASKPASS": askpassPath,
        "SSH_ASKPASS_REQUIRE": "force",
        // DISPLAY needs to be set to _something_ so ssh before 8.4 actually
        // uses SSH_ASKPASS.
        "DISPLAY": ".",
    ]
}

/// The host and key from ssh's prompt to add an unknown host.
public struct AddSSHHostPromptInfo: Sendable, Equatable {
    public let host: String
    public let ip: String
    public let keyType: String
    public let fingerprint: String

    public init(host: String, ip: String, keyType: String, fingerprint: String) {
        self.host = host
        self.ip = ip
        self.keyType = keyType
        self.fingerprint = fingerprint
    }
}

// OpenSSH 9 and earlier write:
//
//     ED25519 key fingerprint is SHA256:abc.
//
// OpenSSH 10 writes `is:` and no final period:
//
//     ED25519 key fingerprint is: SHA256:abc
//
// so this accepts both. Fingerprints (base64 or hexadecimal with colons)
// never contain a period.
private let addSSHHostPromptRe = JSCompat.regex(
    #"^The authenticity of host '([^ ]+) \(([^\)]+)\)' can't be established[^.]*\.\n([^ ]+) key fingerprint is:? ([^.\n]+)(?:\.|\n|\z)"#
)

/// Parses ssh's prompt for adding an unknown host to `known_hosts`, or
/// returns `nil` for any other prompt.
public func parseAddSSHHostPrompt(_ prompt: String) -> AddSSHHostPromptInfo? {
    guard let matches = JSCompat.match(prompt, addSSHHostPromptRe),
          matches.count >= 5,
          let host = matches[1], let ip = matches[2], let keyType = matches[3], let fingerprint = matches[4]
    else {
        return nil
    }

    return AddSSHHostPromptInfo(host: host, ip: ip, keyType: keyType, fingerprint: fingerprint)
}
