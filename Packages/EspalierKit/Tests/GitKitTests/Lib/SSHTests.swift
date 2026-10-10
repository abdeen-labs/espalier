// Ported from desktop/app/test/unit/ssh-test.ts
// Plus tests of the SSH environment, OpenSSH 10's prompt, and other
// prompts.

import GitKit
import Testing
import TestSupport

@Suite("SSH")
struct SSHTests {
    @Test("points ssh at the helper and makes it use askpass")
    func environment() {
        #expect(getSSHEnvironment(askpassPath: "/A/espalier-askpass") == [
            "SSH_ASKPASS": "/A/espalier-askpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ".",
        ])
    }

    @Suite("parsing SSH prompts")
    struct ParsingPrompts {
        @Test("extracts info from prompts to add a host", arguments: [
            NamedCase("extracts info from github.com host key fingerprint", (
                prompt: """
                    The authenticity of host 'github.com (140.82.121.3)' can't be established.
                    RSA key fingerprint is SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
                    """,
                expected: AddSSHHostPromptInfo(
                    host: "github.com",
                    ip: "140.82.121.3",
                    keyType: "RSA",
                    fingerprint: "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
                )
            )),
            NamedCase("extracts info from fake host key fingerprint when keys of different type are available", (
                prompt: """
                    The authenticity of host 'my-domain.com (1.2.3.4)' can't be established
                    but keys of different type are already known for this host.
                    FAKE-TYPE key fingerprint is ThisIsAFakeFingerprintForTestingPurposes.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
                    """,
                expected: AddSSHHostPromptInfo(
                    host: "my-domain.com",
                    ip: "1.2.3.4",
                    keyType: "FAKE-TYPE",
                    fingerprint: "ThisIsAFakeFingerprintForTestingPurposes"
                )
            )),
            // OpenSSH 10 writes "is:" and no final period.
            NamedCase("parses OpenSSH 10's prompt to add a host", (
                prompt: """
                    The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.
                    ED25519 key fingerprint is: SHA256:or8BFH7MTlkYZEw6ZAhnIEcbUWjuvxW82o9UqhPL+4Q
                    This key is not known by any other names.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
                    """,
                expected: AddSSHHostPromptInfo(
                    host: "[127.0.0.1]:2222",
                    ip: "[127.0.0.1]:2222",
                    keyType: "ED25519",
                    fingerprint: "SHA256:or8BFH7MTlkYZEw6ZAhnIEcbUWjuvxW82o9UqhPL+4Q"
                )
            )),
            // An MD5 fingerprint, after text about other keys on the same line.
            NamedCase("parses prompts with extra text about the key", (
                prompt: """
                    The authenticity of host 'example.com (10.0.0.1)' can't be established but keys of different type are already known for this host.
                    RSA key fingerprint is MD5:12:f8:7e:78:61:b7:d2:ab:fb:30:bd:ad:94:1c:29:65.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
                    """,
                expected: AddSSHHostPromptInfo(
                    host: "example.com",
                    ip: "10.0.0.1",
                    keyType: "RSA",
                    fingerprint: "MD5:12:f8:7e:78:61:b7:d2:ab:fb:30:bd:ad:94:1c:29:65"
                )
            )),
        ])
        func addHostPrompts(_ testCase: NamedCase<(prompt: String, expected: AddSSHHostPromptInfo)>) {
            #expect(parseAddSSHHostPrompt(testCase.value.prompt) == testCase.value.expected)
        }

        @Test("ignores other prompts")
        func otherPrompts() {
            #expect(parseAddSSHHostPrompt("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == nil)
            #expect(parseAddSSHHostPrompt("The authenticity of host 'x' is unknown") == nil)
            #expect(parseAddSSHHostPrompt("") == nil)
        }
    }
}
