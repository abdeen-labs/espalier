// What each prompt's answer becomes on its way back to git
// (`PromptPresentation.make`): the SSH host's Yes and No, a key passphrase
// or user password with its Remember checkbox, a username and password, a
// GitHub account, and a failed hook's choice. A swapped login and token, or
// a dropped Remember, would reach git or the keychain.

import EspalierCore
@testable import EspalierUI
import GitHubKit
import GitKit
import Testing

@Suite("Prompt answers") @MainActor
struct PromptPresentationTests {
    /// The answers `finish` received, in order.
    private final class Answers {
        var received: [PromptAnswer?] = []
    }

    private func make(_ prompt: Prompt) -> (PromptPresentation, Answers) {
        let answers = Answers()
        return (PromptPresentation.make(prompt, finish: { answers.received.append($0) }), answers)
    }

    @Test("the SSH host alert's Yes trusts the host, and No doesn't")
    func sshHost() throws {
        let (presentation, answers) = make(.addSSHHost(host: "example.com", ip: "192.0.2.1", keyType: "ED25519", fingerprint: "SHA256:abc"))
        guard case .alert(let content, let answer) = presentation else {
            Issue.record("Expected an alert, got \(presentation)")
            return
        }
        #expect(content.buttons.map(\.title) == ["Yes", "No"])
        #expect(answer(AlertResponse(buttonIndex: 0)) == .addSSHHost(true))
        #expect(answer(AlertResponse(buttonIndex: 1)) == .addSSHHost(false))
        #expect(answers.received.isEmpty)
    }

    @Test("a key passphrase goes back with its Remember choice; Cancel answers nothing", arguments: [true, false])
    func passphrase(remember: Bool) throws {
        let (presentation, answers) = make(.sshKeyPassphrase(keyPath: "/Users/joe/.ssh/id_ed25519"))
        guard case .sheet(.passphrase(let keyPath, let onAnswer)) = presentation else {
            Issue.record("Expected the passphrase sheet, got \(presentation)")
            return
        }
        #expect(keyPath == "/Users/joe/.ssh/id_ed25519")

        onAnswer(SecretPromptAnswer(secret: "correct horse", remember: remember))
        onAnswer(nil)

        #expect(answers.received == [
            .sshSecret(PromptSSHSecretResponse(secret: "correct horse", storeSecret: remember)),
            nil,
        ])
    }

    @Test("an SSH user password goes back with its Remember choice; Cancel answers nothing", arguments: [true, false])
    func password(remember: Bool) throws {
        let (presentation, answers) = make(.sshUserPassword(username: "joe@example.com"))
        guard case .sheet(.password(let username, let onAnswer)) = presentation else {
            Issue.record("Expected the password sheet, got \(presentation)")
            return
        }
        #expect(username == "joe@example.com")

        onAnswer(SecretPromptAnswer(secret: "hunter2", remember: remember))
        onAnswer(nil)

        #expect(answers.received == [
            .sshSecret(PromptSSHSecretResponse(secret: "hunter2", storeSecret: remember)),
            nil,
        ])
    }

    @Test("a username and password go back as the login and token for the endpoint; Cancel answers nothing")
    func genericAuthentication() throws {
        let endpoint = "https://git.example.com/team/project.git"
        let (presentation, answers) = make(.genericGitAuthentication(endpoint: endpoint, username: nil))
        guard case .sheet(.genericAuthentication(let shownEndpoint, let username, let onAnswer)) = presentation else {
            Issue.record("Expected the authentication sheet, got \(presentation)")
            return
        }
        #expect(shownEndpoint == endpoint)
        #expect(username == nil)

        onAnswer(GenericAuthAnswer(username: "joe", password: "token-123"))
        onAnswer(nil)

        #expect(answers.received == [
            .credentials(TrampolineAccount(endpoint: endpoint, login: "joe", token: "token-123")),
            nil,
        ])
    }

    @Test("the authentication sheet answers with the username git asked about, else the one entered")
    func genericAuthenticationUsername() {
        #expect(GenericAuthPrompt.answer(knownUsername: "git-user", enteredUsername: "", password: "secret")
            == GenericAuthAnswer(username: "git-user", password: "secret"))
        #expect(GenericAuthPrompt.answer(knownUsername: nil, enteredUsername: "typed", password: "secret")
            == GenericAuthAnswer(username: "typed", password: "secret"))
    }

    @Test("a GitHub sign-in goes back as the account's login and token; closing it answers without an account")
    func gitHubSignIn() throws {
        let endpoint = "https://api.github.com"
        let (presentation, answers) = make(.gitHubSignIn(endpoint: endpoint))
        guard case .sheet(.signIn(let shownEndpoint, let onFinish)) = presentation else {
            Issue.record("Expected the sign-in sheet, got \(presentation)")
            return
        }
        #expect(shownEndpoint == endpoint)

        onFinish(Account(login: "octocat", endpoint: endpoint, token: "gho_token", emails: [], avatarURL: "", id: 1, name: "The Octocat"))
        onFinish(nil)

        #expect(answers.received == [
            .credentials(TrampolineAccount(endpoint: endpoint, login: "octocat", token: "gho_token")),
            .credentials(nil),
        ])
    }

    @Test("a failed hook's Ignore and Continue ignores it, and Abort aborts")
    func hookFailed() throws {
        let (presentation, answers) = make(.hookFailed(hookName: "pre-commit", terminalOutput: "lint failed\n"))
        guard case .sheet(.hookFailed(let hookName, let output, let onAnswer)) = presentation else {
            Issue.record("Expected the hook sheet, got \(presentation)")
            return
        }
        #expect(hookName == "pre-commit")
        #expect(output == "lint failed\n")

        onAnswer(.ignore)
        onAnswer(.abort)

        #expect(answers.received == [.hookFailure(.ignore), .hookFailure(.abort)])
    }
}
