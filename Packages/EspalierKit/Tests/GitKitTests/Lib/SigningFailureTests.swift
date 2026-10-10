// Git's output here was recorded from git 2.53 with GnuPG 2.5 (gpg, gpgsm,
// pinentry 1.3) and OpenSSH 10's ssh-keygen, except pinentry-mac's (a
// window that tests can't answer), which follows GnuPG's status lines. The
// signing tests in EspalierCoreTests check live runs.

import GitKit
import Testing

@Suite("parseSigningFailure")
struct SigningFailureTests {
    @Test("a pinentry that needs a terminal, however it fails")
    func pinentryNeedsTerminal() {
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] KEY_CONSIDERED 812FB5A8314569283AF4BD0A924353156B8D318C 2
            [GNUPG:] BEGIN_SIGNING H10
            [GNUPG:] PINENTRY_LAUNCHED 19687 curses 1.3.3 - - . - 501/20 0
            gpg: signing failed: Inappropriate ioctl for device
            [GNUPG:] FAILURE sign 83918950
            gpg: signing failed: Inappropriate ioctl for device

            fatal: failed to write commit object

            """) == .pinentryNeedsTerminal(pinentry: "pinentry-curses"))
        // GPG_TTY set to "not a tty" by `export GPG_TTY=$(tty)` in a
        // startup file.
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] PINENTRY_LAUNCHED 19759 curses 1.3.3 not a tty - . ? 501/20 0
            gpg: signing failed: No such file or directory
            [GNUPG:] FAILURE sign 83918929

            fatal: failed to write commit object

            """) == .pinentryNeedsTerminal(pinentry: "pinentry-curses"))
        // pinentry-tty reports the missing terminal as a cancellation.
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] PINENTRY_LAUNCHED 19854 tty 1.3.3 - - . - 501/20 0
            gpg: signing failed: Operation cancelled
            [GNUPG:] FAILURE sign 83886179

            fatal: failed to write commit object

            """) == .pinentryNeedsTerminal(pinentry: "pinentry-tty"))
    }

    @Test("GPG's other failures")
    func gpgFailures() {
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            gpg: skipped "DEADBEEFDEADBEEF": No secret key
            [GNUPG:] INV_SGNR 9 DEADBEEFDEADBEEF
            [GNUPG:] FAILURE sign 17
            gpg: signing failed: No secret key

            fatal: failed to write commit object

            """) == .noSecretKey(key: "DEADBEEFDEADBEEF"))
        #expect(parseSigningFailure("""
            error: cannot run gpg: No such file or directory
            error: gpg failed to sign the data:
            (no gpg output)
            fatal: failed to write commit object

            """) == .programNotFound(program: "gpg"))
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            gpg: can't connect to the gpg-agent: IPC connect call failed
            gpg: keydb_search failed: No agent running
            gpg: skipped "A6A70D99C9BFBBFAF1CEE4599DDA404E0A123D75": No agent running
            [GNUPG:] INV_SGNR 0 A6A70D99C9BFBBFAF1CEE4599DDA404E0A123D75
            [GNUPG:] FAILURE sign 33554509
            gpg: signing failed: No agent running

            fatal: failed to write commit object

            """) == .noAgent)
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] PINENTRY_LAUNCHED 2244 mac 1.3.1 - - . - 501/20 0
            gpg: signing failed: Operation cancelled
            [GNUPG:] FAILURE sign 83886179

            fatal: failed to write commit object

            """) == .cancelled)
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] PINENTRY_LAUNCHED 2244 mac 1.3.1 - - . - 501/20 0
            gpg: signing failed: Bad passphrase
            [GNUPG:] FAILURE sign 11

            fatal: failed to write commit object

            """) == .badPassphrase)
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] KEY_CONSIDERED D3AFCB7B33A039511C6CED5AB4951F6FA95EED39 2
            [GNUPG:] BEGIN_SIGNING H10
            gpg: signing failed: No pinentry
            [GNUPG:] FAILURE sign 67108949
            gpg: signing failed: No pinentry

            fatal: failed to write commit object

            """) == .pinentryUnavailable)
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            [GNUPG:] KEY_CONSIDERED A39579A019D667D0ADC26D5A5FAFDA49437576DF 3
            gpg: skipped "old@example.com": Unusable secret key
            [GNUPG:] INV_SGNR 9 old@example.com
            [GNUPG:] FAILURE sign 54
            gpg: signing failed: Unusable secret key

            fatal: failed to write commit object

            """) == .unusableKey(key: "old@example.com"))
        #expect(parseSigningFailure("error: gpg failed to sign the data:\ngpg: something new\n\nfatal: failed to write commit object\n") == .other)
    }

    @Test("gpgsm, for X.509 certificates")
    func gpgsm() {
        #expect(parseSigningFailure("""
            error: gpg failed to sign the data:
            gpgsm: can't sign using 'A6A70D99C9BFBBFAF1CEE4599DDA404E0A123D75': No public key
            [GNUPG:] INV_SGNR 1 A6A70D99C9BFBBFAF1CEE4599DDA404E0A123D75
            [GNUPG:] FAILURE gpgsm-exit 50331649

            fatal: failed to write commit object

            """) == .noSecretKey(key: "A6A70D99C9BFBBFAF1CEE4599DDA404E0A123D75"))
        #expect(parseSigningFailure("""
            error: cannot run gpgsm: No such file or directory
            error: gpg failed to sign the data:
            (no gpg output)
            fatal: failed to write commit object

            """) == .programNotFound(program: "gpgsm"))
        #expect(parseSigningFailure("""
            fatal: cannot exec '/nonexistent/gpgsm': No such file or directory
            error: gpg failed to sign the data:
            (no gpg output)
            fatal: failed to write commit object

            """) == .programNotFound(program: "/nonexistent/gpgsm"))
    }

    @Test("ssh-keygen's failures")
    func ssh() {
        #expect(parseSigningFailure("fatal: either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured\n") == .sshKeyNotConfigured)
        #expect(parseSigningFailure("error: Couldn't get agent socket?\n\nfatal: failed to write commit object\n") == .sshAgentUnavailable)
        #expect(parseSigningFailure("error: Couldn't find key in agent?\n\nerror: failed to write commit object\n") == .sshKeyNotInAgent)
        #expect(parseSigningFailure("""
            error: Load key "/Users/joe/.ssh/id_ed25519": incorrect passphrase supplied to decrypt private key?

            fatal: failed to write commit object

            """) == .badPassphrase)
        #expect(parseSigningFailure("""
            error: No private key found for public key "/Users/joe/.ssh/id_ed25519.pub"?

            fatal: failed to write commit object

            """) == .sshPrivateKeyNotFound(path: "/Users/joe/.ssh/id_ed25519.pub"))
        #expect(parseSigningFailure("""
            error: Couldn't load public key /Users/joe/.ssh/missing: No such file or directory?

            fatal: failed to write commit object

            """) == .sshKeyNotFound(path: "/Users/joe/.ssh/missing"))
        #expect(parseSigningFailure("fatal: cannot exec '/nonexistent/ssh-keygen': No such file or directory\nerror: \nfatal: failed to write commit object\n") == .programNotFound(program: "/nonexistent/ssh-keygen"))
        // A tag.
        #expect(parseSigningFailure("error: Couldn't find key in agent?\n\nerror: unable to sign the tag\nThe tag message has been left in .git/TAG_EDITMSG\n") == .sshKeyNotInAgent)
    }

    @Test("isn't a signing failure")
    func notSigning() {
        #expect(parseSigningFailure("") == nil)
        #expect(parseSigningFailure("error: insufficient permission for adding an object to repository database .git/objects\nfatal: failed to write commit object\n") == nil)
        // ssh, the transport, has its own wording for an agent without the
        // key; without git's signing error it isn't a signing failure.
        #expect(parseSigningFailure("Load key \"/Users/joe/.ssh/id_ed25519\": incorrect passphrase supplied to decrypt private key\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n") == nil)
    }
}
