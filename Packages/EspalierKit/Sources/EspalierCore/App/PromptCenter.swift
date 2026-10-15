import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "prompts")

/// Something git needs from the user while an operation runs.
public enum Prompt: Sendable, Equatable {
    /// ssh doesn't know the host's key: add it to `known_hosts` and connect?
    case addSSHHost(host: String, ip: String, keyType: String, fingerprint: String)
    /// The passphrase for the SSH key at `keyPath`, offering to remember it
    /// when `canRemember`.
    case sshKeyPassphrase(keyPath: String, canRemember: Bool)
    /// The password for `username` (`user@host`).
    case sshUserPassword(username: String)
    /// A username and password (or token) for a host that isn't GitHub.
    case genericGitAuthentication(endpoint: String, username: String?)
    /// Signing in to the GitHub host at `endpoint` is needed.
    case gitHubSignIn(endpoint: String)
    /// A hook failed: ignore the failure and continue, or abort.
    case hookFailed(hookName: String, terminalOutput: String)

    /// The answer when the prompt is dismissed, or when the operation that
    /// asked ends first. Dismissing a failed hook's prompt aborts.
    public var cancelledAnswer: PromptAnswer {
        switch self {
        case .addSSHHost: .addSSHHost(false)
        case .sshKeyPassphrase, .sshUserPassword: .sshSecret(PromptSSHSecretResponse(secret: nil, storeSecret: false))
        case .genericGitAuthentication, .gitHubSignIn: .credentials(nil)
        case .hookFailed: .hookFailure(.abort)
        }
    }

    /// Whether `answer` answers this kind of prompt.
    public func accepts(_ answer: PromptAnswer) -> Bool {
        switch (self, answer) {
        case (.addSSHHost, .addSSHHost),
             (.sshKeyPassphrase, .sshSecret), (.sshUserPassword, .sshSecret),
             (.genericGitAuthentication, .credentials), (.gitHubSignIn, .credentials),
             (.hookFailed, .hookFailure):
            true
        default:
            false
        }
    }
}

/// The user's answer to a `Prompt`.
public enum PromptAnswer: Sendable, Equatable {
    /// Whether to trust the host.
    case addSSHHost(Bool)
    /// The passphrase or password, or nil when cancelled.
    case sshSecret(PromptSSHSecretResponse)
    /// The credentials or account, or nil when dismissed.
    case credentials(TrampolineAccount?)
    /// What to do about the failed hook.
    case hookFailure(HookFailureResolution)
}

/// A prompt waiting for an answer.
public struct PendingPrompt: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let prompt: Prompt
}

/// The prompts git is waiting on, in the order they were asked.
///
/// The UI shows `current` and calls `answer(_:with:)`; tests set a
/// `responder` that answers in code and check `history`. When the git
/// operation that asked ends first, its prompt is removed and answered with
/// `Prompt.cancelledAnswer`.
@MainActor @Observable
public final class PromptCenter: TrampolinePrompter {
    /// Answers prompts in code, one at a time, in order.
    public typealias Responder = @MainActor (Prompt) async -> PromptAnswer

    /// The prompts waiting for an answer, oldest first.
    public private(set) var pending: [PendingPrompt] = []

    /// Every prompt asked, in order.
    public private(set) var history: [Prompt] = []

    /// When set, answers each prompt instead of the UI.
    @ObservationIgnored public var responder: Responder? {
        didSet { respondToNext() }
    }

    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<PromptAnswer, Never>] = [:]
    @ObservationIgnored private var isResponding = false

    public init(responder: Responder? = nil) {
        self.responder = responder
    }

    /// The prompt to show now.
    public var current: PendingPrompt? {
        pending.first
    }

    /// Answers the prompt `id`. An answer of the wrong kind counts as
    /// dismissing it.
    public func answer(_ id: UUID, with answer: PromptAnswer) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        let prompt = pending.remove(at: index).prompt
        var answer = answer
        if !prompt.accepts(answer) {
            logger.error("A prompt was answered with an answer of the wrong kind; treating it as dismissed")
            answer = prompt.cancelledAnswer
        }
        continuations.removeValue(forKey: id)?.resume(returning: answer)
    }

    /// Dismisses the prompt `id`: it gets its cancelled answer.
    public func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        let prompt = pending.remove(at: index).prompt
        continuations.removeValue(forKey: id)?.resume(returning: prompt.cancelledAnswer)
    }

    /// Asks `prompt` and waits for the answer.
    public func ask(_ prompt: Prompt) async -> PromptAnswer {
        let id = UUID()
        history.append(prompt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PromptAnswer, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: prompt.cancelledAnswer)
                    return
                }
                continuations[id] = continuation
                pending.append(PendingPrompt(id: id, prompt: prompt))
                respondToNext()
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(id)
            }
        }
    }

    private func respondToNext() {
        guard let responder, !isResponding, let next = pending.first else {
            return
        }
        isResponding = true
        Task {
            let answer = await responder(next.prompt)
            self.isResponding = false
            self.answer(next.id, with: answer)
            self.respondToNext()
        }
    }

    // MARK: TrampolinePrompter

    public func promptAddingSSHHost(host: String, ip: String, keyType: String, fingerprint: String) async -> Bool {
        guard case .addSSHHost(let add) = await ask(.addSSHHost(host: host, ip: ip, keyType: keyType, fingerprint: fingerprint)) else {
            return false
        }
        return add
    }

    public func promptSSHKeyPassphrase(keyPath: String, canRemember: Bool) async -> PromptSSHSecretResponse {
        guard case .sshSecret(let response) = await ask(.sshKeyPassphrase(keyPath: keyPath, canRemember: canRemember)) else {
            return PromptSSHSecretResponse(secret: nil, storeSecret: false)
        }
        return response
    }

    public func promptSSHUserPassword(username: String) async -> PromptSSHSecretResponse {
        guard case .sshSecret(let response) = await ask(.sshUserPassword(username: username)) else {
            return PromptSSHSecretResponse(secret: nil, storeSecret: false)
        }
        return response
    }

    public func promptForGenericGitAuthentication(endpoint: String, username: String?) async -> TrampolineAccount? {
        guard case .credentials(let account) = await ask(.genericGitAuthentication(endpoint: endpoint, username: username)) else {
            return nil
        }
        return account
    }

    public func promptForGitHubSignIn(endpoint: String) async -> TrampolineAccount? {
        guard case .credentials(let account) = await ask(.gitHubSignIn(endpoint: endpoint)) else {
            return nil
        }
        return account
    }

    public func promptHookFailure(hookName: String, terminalOutput: String) async -> HookFailureResolution {
        guard case .hookFailure(let resolution) = await ask(.hookFailed(hookName: hookName, terminalOutput: terminalOutput)) else {
            return .abort
        }
        return resolution
    }
}
