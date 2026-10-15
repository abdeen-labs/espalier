@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing

@Suite("Prompt center") @MainActor
struct PromptCenterTests {
    /// Waits until `count` prompts are pending.
    private func waitForPending(_ center: PromptCenter, _ count: Int) async throws {
        for _ in 0..<10_000 where center.pending.count < count {
            await Task.yield()
        }
        try #require(center.pending.count >= count)
    }

    @Test("queues prompts in the order they were asked and answers each its own")
    func fifo() async throws {
        let center = PromptCenter()
        let first = Task { await center.promptHookFailure(hookName: "pre-commit", terminalOutput: "lint failed") }
        try await waitForPending(center, 1)
        let second = Task { await center.promptAddingSSHHost(host: "github.com", ip: "140.82.112.3", keyType: "ED25519", fingerprint: "SHA256:+DiY3wvv") }
        try await waitForPending(center, 2)
        let third = Task { await center.promptSSHKeyPassphrase(keyPath: "/Users/me/.ssh/id_ed25519", canRemember: true) }
        try await waitForPending(center, 3)

        #expect(center.pending.map(\.prompt) == [
            .hookFailed(hookName: "pre-commit", terminalOutput: "lint failed"),
            .addSSHHost(host: "github.com", ip: "140.82.112.3", keyType: "ED25519", fingerprint: "SHA256:+DiY3wvv"),
            .sshKeyPassphrase(keyPath: "/Users/me/.ssh/id_ed25519", canRemember: true),
        ])
        #expect(center.current?.prompt == .hookFailed(hookName: "pre-commit", terminalOutput: "lint failed"))

        // Answering out of order still answers the right prompts.
        let ids = center.pending.map(\.id)
        center.answer(ids[1], with: .addSSHHost(true))
        center.answer(ids[0], with: .hookFailure(.ignore))
        center.answer(ids[2], with: .sshSecret(PromptSSHSecretResponse(secret: "hunter2", storeSecret: true)))

        #expect(await first.value == .ignore)
        #expect(await second.value == true)
        #expect(await third.value == PromptSSHSecretResponse(secret: "hunter2", storeSecret: true))
        #expect(center.pending.isEmpty)
        #expect(center.history.count == 3)
    }

    @Test("a prompt whose operation ends first is removed and gets its cancelled answer")
    func cancellation() async throws {
        let center = PromptCenter()
        let hook = Task { await center.promptHookFailure(hookName: "pre-push", terminalOutput: "") }
        try await waitForPending(center, 1)
        let host = Task { await center.promptAddingSSHHost(host: "example.com", ip: "1.2.3.4", keyType: "RSA", fingerprint: "SHA256:x") }
        try await waitForPending(center, 2)

        hook.cancel()
        #expect(await hook.value == .abort)
        for _ in 0..<10_000 where center.pending.count > 1 {
            await Task.yield()
        }
        #expect(center.pending.map(\.prompt) == [.addSSHHost(host: "example.com", ip: "1.2.3.4", keyType: "RSA", fingerprint: "SHA256:x")])

        host.cancel()
        #expect(await host.value == false)
    }

    @Test("dismissing gives each kind of prompt its cancelled answer")
    func dismissing() async throws {
        let center = PromptCenter()
        let password = Task { await center.promptSSHUserPassword(username: "git@example.com") }
        let credentials = Task { await center.promptForGenericGitAuthentication(endpoint: "https://example.com", username: nil) }
        let signIn = Task { await center.promptForGitHubSignIn(endpoint: "https://api.github.com") }
        try await waitForPending(center, 3)
        for prompt in center.pending {
            center.cancel(prompt.id)
        }
        #expect(await password.value == PromptSSHSecretResponse(secret: nil, storeSecret: false))
        #expect(await credentials.value == nil)
        #expect(await signIn.value == nil)
    }

    @Test("an answer of the wrong kind counts as dismissing")
    func wrongKind() async throws {
        let center = PromptCenter()
        let hook = Task { await center.promptHookFailure(hookName: "commit-msg", terminalOutput: "") }
        try await waitForPending(center, 1)
        center.answer(try #require(center.current).id, with: .addSSHHost(true))
        #expect(await hook.value == .abort)
    }

    @Test("a responder answers prompts in order, one at a time")
    func responder() async {
        let answered = AnsweredPrompts()
        let center = PromptCenter { prompt in
            answered.prompts.append(prompt)
            await Task.yield()
            if case .hookFailed = prompt {
                return .hookFailure(.ignore)
            }
            return prompt.cancelledAnswer
        }
        async let hook = center.promptHookFailure(hookName: "pre-commit", terminalOutput: "")
        async let host = center.promptAddingSSHHost(host: "h", ip: "i", keyType: "k", fingerprint: "f")
        let (resolution, trusted) = await (hook, host)
        #expect(resolution == .ignore)
        #expect(trusted == false)
        #expect(answered.prompts.count == 2)
        #expect(center.pending.isEmpty)
    }

    @Test("a prompt asked by a task already cancelled gets its cancelled answer")
    func alreadyCancelled() async {
        let center = PromptCenter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await center.promptHookFailure(hookName: "pre-commit", terminalOutput: "")
        }
        #expect(await task.value == .abort)
        #expect(center.pending.isEmpty)
    }
}

@MainActor
private final class AnsweredPrompts {
    var prompts: [Prompt] = []
}
