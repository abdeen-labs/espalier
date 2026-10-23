// Shows the prompts git waits on (`PromptCenter`), one at a time and in
// order. Dismissing a prompt answers it with its cancelled answer; a prompt
// whose operation ended first is closed.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// How a prompt is shown: an alert, or a sheet.
enum PromptPresentation {
    /// An alert, and the answer for the button chosen.
    case alert(AlertContent, answer: (AlertResponse) -> PromptAnswer)
    /// A sheet whose content answers through `finish` (nil: dismissed).
    case sheet(PromptSheet)

    /// The presentation of `prompt`; the sheet's buttons call `finish`.
    @MainActor
    static func make(_ prompt: Prompt, finish: @escaping (PromptAnswer?) -> Void) -> PromptPresentation {
        switch prompt {
        case .addSSHHost(let host, let ip, let keyType, let fingerprint):
            return .alert(SSHHostPrompt.alert(host: host, ip: ip, keyType: keyType, fingerprint: fingerprint)) { response in
                .addSSHHost(response.buttonIndex == 0)
            }

        case .sshKeyPassphrase(let keyPath, let canRemember):
            return .sheet(.passphrase(keyPath: keyPath, canRemember: canRemember) { answer in
                finish(answer.map { .sshSecret(PromptSSHSecretResponse(secret: $0.secret, storeSecret: $0.remember)) })
            })

        case .sshUserPassword(let username):
            return .sheet(.password(username: username) { answer in
                finish(answer.map { .sshSecret(PromptSSHSecretResponse(secret: $0.secret, storeSecret: $0.remember)) })
            })

        case .genericGitAuthentication(let endpoint, let username):
            return .sheet(.genericAuthentication(endpoint: endpoint, username: username) { answer in
                finish(answer.map {
                    .credentials(TrampolineAccount(endpoint: endpoint, login: $0.username, token: $0.password))
                })
            })

        case .gitHubSignIn(let endpoint):
            return .sheet(.signIn(endpoint: endpoint) { account in
                finish(.credentials(account.map {
                    TrampolineAccount(endpoint: $0.endpoint, login: $0.login, token: $0.token)
                }))
            })

        case .repositoryAccount(let request):
            return .sheet(.repositoryAccount(request) { identity in
                finish(identity.map { .repositoryAccount($0) })
            })

        case .hookFailed(let hookName, let terminalOutput):
            return .sheet(.hookFailed(hookName: hookName, terminalOutput: terminalOutput) { answer in
                finish(.hookFailure(answer == .ignore ? .ignore : .abort))
            })
        }
    }
}

/// A prompt's sheet, with the callback its buttons answer through: what
/// `PromptPresentation.make` turns into the answer git gets back.
enum PromptSheet {
    case passphrase(keyPath: String, canRemember: Bool, onAnswer: (SecretPromptAnswer?) -> Void)
    case password(username: String, onAnswer: (SecretPromptAnswer?) -> Void)
    case genericAuthentication(endpoint: String, username: String?, onAnswer: (GenericAuthAnswer?) -> Void)
    case signIn(endpoint: String, onFinish: (Account?) -> Void)
    case repositoryAccount(RepositoryAccountRequest, onAnswer: (AccountIdentity?) -> Void)
    case hookFailed(hookName: String, terminalOutput: String, onAnswer: (HookFailedPrompt.Answer) -> Void)

    /// The sheet's view.
    @MainActor
    var view: AnyView {
        switch self {
        case .passphrase(let keyPath, let canRemember, let onAnswer):
            AnyView(PassphrasePrompt(keyPath: keyPath, canRemember: canRemember, onAnswer: onAnswer))
        case .password(let username, let onAnswer):
            AnyView(PasswordPrompt(username: username, onAnswer: onAnswer))
        case .genericAuthentication(let endpoint, let username, let onAnswer):
            AnyView(GenericAuthPrompt(endpoint: endpoint, username: username, onAnswer: onAnswer))
        case .signIn(let endpoint, let onFinish):
            AnyView(SignInSheet(request: SignInRequest(endpoint: endpoint, reason: .gitRequestedCredentials(url: endpoint)), onFinish: onFinish))
        case .repositoryAccount(let request, let onAnswer):
            AnyView(RepositoryAccountPrompt(request: request, onAnswer: onAnswer))
        case .hookFailed(let hookName, let terminalOutput, let onAnswer):
            AnyView(HookFailedPrompt(hookName: hookName, terminalOutput: terminalOutput, onAnswer: onAnswer))
        }
    }
}

/// Shows `PromptCenter.current` on the main window.
@MainActor
final class PromptHost {
    static let modalID = "espalier.prompt"

    private weak var context: WindowContext?
    /// The prompt on screen, if any.
    private var shownID: UUID?

    init(context: WindowContext) {
        self.context = context
    }

    /// Shows the current prompt, and closes one that's no longer pending.
    func update() {
        guard let context else {
            return
        }
        let prompts = context.app.prompts
        if let shownID, !prompts.pending.contains(where: { $0.id == shownID }) {
            self.shownID = nil
            context.modals.dismissSheet(id: Self.modalID)
            context.modals.dismissAlert(id: Self.modalID)
        }
        guard shownID == nil, let current = prompts.current else {
            return
        }
        shownID = current.id
        // The modal presenter asks for attention while Espalier is inactive.
        show(current, prompts: prompts, modals: context.modals)
    }

    private func show(_ pending: PendingPrompt, prompts: PromptCenter, modals: ModalPresenter) {
        let id = pending.id
        let session = Session()
        let finish: (PromptAnswer?) -> Void = { [weak self] answer in
            // A sheet's own buttons close it, which calls this again.
            guard !session.isFinished else {
                return
            }
            session.isFinished = true
            if let answer {
                prompts.answer(id, with: answer)
            } else {
                prompts.cancel(id)
            }
            modals.dismissSheet(id: Self.modalID)
            if self?.shownID == id {
                self?.shownID = nil
            }
            self?.update()
        }

        switch PromptPresentation.make(pending.prompt, finish: finish) {
        case .alert(let content, let answer):
            Task {
                let response = await modals.alert(content, id: Self.modalID)
                finish(answer(response))
            }
        case .sheet(let sheet):
            let content = sheet.view
            modals.presentSheet(id: Self.modalID, onDismiss: { finish(nil) }) {
                content
            }
        }
    }

    /// Whether a prompt on screen has been answered.
    private final class Session {
        var isFinished = false
    }
}
