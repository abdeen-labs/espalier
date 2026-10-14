// How each `OperationError` is shown. The titles, messages, and recovery
// titles are the state layer's; this file picks the alert or sheet, lists
// files, and maps buttons to recoveries.

import EspalierCore
import GitKit
import SwiftUI

/// How an error is shown.
public enum ErrorPresentation {
    /// An alert whose first buttons run `recoveries`, in order; its last
    /// button closes it.
    case alert(AlertContent, recoveries: [Recovery])
    /// Git's raw output in a sheet.
    case rawOutput(RawOutputContent, recoveries: [Recovery])
    /// Secrets found by push protection: `PushProtectionSheet`.
    case pushProtection
    /// No write access: `CreateForkSheet`.
    case createFork
    /// Nothing: the Missing or Unsafe view takes over, or the user cancelled.
    case none
}

extension OperationError {
    /// How the error is shown, the counts in its lists in `numberFormat`.
    public func presentation(_ numberFormat: NumberFormat) -> ErrorPresentation {
        switch reason {
        case .missingRepository, .unsafeRepository, .cancelled, .confirmationRequired, .decisionRequired:
            return .none
        case .pushProtectionBlocked:
            return .pushProtection
        case .insufficientPermissions:
            return .createFork
        default:
            break
        }
        if isRawGitOutput, let failure = gitFailure {
            var note: String?
            if message != failure.message, message.hasPrefix(failure.message) {
                note = String(message.dropFirst(failure.message.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return .rawOutput(
                RawOutputContent(
                    title: title,
                    message: leadMessage,
                    output: failure.message,
                    note: note,
                    recoveryTitles: recoveries.map(\.title),
                    dismissTitle: dismissTitle
                ),
                recoveries: recoveries
            )
        }
        var buttons = recoveries.enumerated().map { index, recovery in
            AlertContent.Button(recovery.title, role: index == 0 ? .primary : .secondary)
        }
        if recoveries.isEmpty {
            buttons.append(AlertContent.Button(dismissTitle, role: .primary))
        } else {
            buttons.append(AlertContent.Button(dismissTitle, role: .cancel))
        }
        let alertMessage = alertMessage(numberFormat)
        let message = leadMessage.map { "\($0)\n\n\(alertMessage)" } ?? alertMessage
        return .alert(
            AlertContent(
                title: title,
                message: message,
                buttons: buttons,
                suppressionTitle: isSuppressible && !recoveries.isEmpty ? AlertContent.doNotShowAgain : nil,
                severity: isCriticalAlert ? .critical : .standard
            ),
            recoveries: recoveries
        )
    }

    /// The setting the alert's "Do not show this message again" turns off
    /// when the user goes ahead with a recovery: the Trash failure's
    /// `confirmDiscardChangesPermanently` (written after Permanently Discard
    /// Changes, never after Cancel).
    @MainActor
    public var suppressionSetting: ReferenceWritableKeyPath<Preferences, Bool>? {
        isSuppressible ? \.confirmDiscardChangesPermanently : nil
    }

    /// Whether the alert offers "Do not show this message again".
    private var isSuppressible: Bool {
        if case .trashFailed = reason { true } else { false }
    }

    /// A line before git's message saying what failed: why a commit couldn't
    /// be signed and what to do, or the delete-worktree failure's "Couldn't
    /// delete the worktree <name>."
    private var leadMessage: String? {
        if let explanation = signingFailureExplanation {
            return explanation
        }
        guard retry?.kind == .removeWorktree, let name = retry?.displayName else {
            return nil
        }
        return "Couldn't delete the worktree \(name)."
    }

    /// The button that closes the alert: "Close", "Cancel" where the alert
    /// asks a question (Retry Clone, Delete Anyway), "Not Now" for the LFS
    /// filters.
    private var dismissTitle: String {
        switch reason {
        case .lfsAttributeMismatch:
            return "Not Now"
        case .pushRejectedNonFastForward, .trashFailed, .workflowScopeRequired, .samlReauthorizationRequired:
            return "Cancel"
        default:
            switch retry?.kind {
            case .clone?, .removeWorktree?:
                return recoveries.isEmpty ? "Close" : "Cancel"
            default:
                return "Close"
            }
        }
    }

    /// The message with the files listed.
    private func alertMessage(_ numberFormat: NumberFormat) -> String {
        switch reason {
        case .fileSizeLimitExceeded(let files) where !files.isEmpty:
            return "\(message)\n\nFiles over the limit:\n\(AlertList.lines(files, numberFormat: numberFormat))"
        case .localChangesOverwritten(let files):
            var text = message
            if !files.isEmpty {
                text += "\n\n\(AlertList.lines(files, numberFormat: numberFormat))"
            }
            if recoveries.contains(where: { if case .stashChangesAndRetry = $0 { true } else { false } }) {
                text += "\n\nYou can stash your changes now and restore them afterward."
            }
            return text
        default:
            return message
        }
    }

    /// Unrecoverable discards are critical.
    private var isCriticalAlert: Bool {
        if case .trashFailed = reason { true } else { false }
    }
}

/// Shows the presenter's errors.
@MainActor
enum ErrorHost {
    static let sheetID = "espalier.error"

    static func present(_ presented: PresentedError, in context: WindowContext) {
        let presenter = context.presenter
        let modals = context.modals
        let id = presented.id
        switch presented.error.presentation(context.app.preferences.numberFormat) {
        case .alert(let content, let recoveries):
            let preferences = context.app.preferences
            Task {
                let response = await modals.alert(content)
                if let recovery = respond(response, to: presented.error, recoveries: recoveries, preferences: preferences) {
                    await presenter.recover(id, with: recovery)
                } else {
                    presenter.dismissError(id)
                }
            }

        case .rawOutput(let content, let recoveries):
            modals.presentSheet(id: sheetID, onDismiss: {
                presenter.dismissError(id)
            }) {
                RawOutputSheet(content, onRecovery: { index in
                    modals.dismissSheet(id: sheetID)
                    guard recoveries.indices.contains(index) else {
                        return
                    }
                    Task { await presenter.recover(id, with: recoveries[index]) }
                }, onClose: {
                    modals.dismissSheet(id: sheetID)
                })
            }

        case .pushProtection:
            modals.presentSheet(id: sheetID, onDismiss: {
                presenter.dismissError(id)
            }) {
                PushProtectionSheet(error: presented.error)
            }

        case .createFork:
            modals.presentSheet(id: sheetID, onDismiss: {
                presenter.dismissError(id)
            }) {
                CreateForkSheet(error: presented.error)
            }

        case .none:
            presenter.dismissError(id)
        }
    }

    /// The recovery an alert's answer chose, or nil for its dismiss button.
    /// Going ahead with "Do not show this message again" on turns the
    /// error's setting off (`suppressionSetting`).
    static func respond(
        _ response: AlertResponse,
        to error: OperationError,
        recoveries: [Recovery],
        preferences: Preferences
    ) -> Recovery? {
        guard recoveries.indices.contains(response.buttonIndex) else {
            return nil
        }
        if response.isSuppressed, let setting = error.suppressionSetting {
            preferences[keyPath: setting] = false
        }
        return recoveries[response.buttonIndex]
    }
}
