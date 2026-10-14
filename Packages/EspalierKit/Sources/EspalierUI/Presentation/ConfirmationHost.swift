// How each of the state layer's 21 confirmations is shown. The copy is the
// state layer's (`Confirmation`); this file decides alert or compact sheet,
// button roles, severity, lists, and the checkbox. Remove Repository and
// Delete Branch are Espalier's compact sheets: their option is Espalier's
// checkbox ("Also move the folder to the Trash", "Delete it on the remote
// too"), and Remove or Delete is the default button. The others are
// alerts, with "Do not show this message again" where the confirmation can
// be turned off.

import EspalierCore
import GitKit
import SwiftUI

/// How a confirmation is shown.
nonisolated public enum ConfirmationPresentation: Sendable, Equatable {
    case alert(AlertContent)
    /// Espalier's compact sheet, for a confirmation with an option of its
    /// own.
    case compactSheet(CompactConfirmation)
}

/// A compact confirmation sheet's content.
nonisolated public struct CompactConfirmation: Sendable, Equatable {
    public var title: String
    /// The paragraphs, in order.
    public var paragraphs: [String]
    /// A path shown monospaced after the paragraphs, if any.
    public var path: String?
    /// The checkbox's title, or nil for none.
    public var optionTitle: String?
    public var confirmButton: String
    public var isDestructive: Bool

    public init(title: String, paragraphs: [String], path: String? = nil, optionTitle: String? = nil, confirmButton: String, isDestructive: Bool) {
        self.title = title
        self.paragraphs = paragraphs
        self.path = path
        self.optionTitle = optionTitle
        self.confirmButton = confirmButton
        self.isDestructive = isDestructive
    }
}

extension Confirmation {
    /// How the confirmation is shown, the counts in its lists in
    /// `numberFormat`.
    @MainActor
    public func presentation(_ numberFormat: NumberFormat) -> ConfirmationPresentation {
        switch kind {
        case .removeRepository:
            var path: String?
            if case .repository(_, let repositoryPath) = details {
                path = repositoryPath
            }
            return .compactSheet(CompactConfirmation(
                title: title,
                paragraphs: [message, "Its folder stays on your Mac:"],
                path: path,
                optionTitle: "Also move the folder to the Trash",
                confirmButton: confirmButton,
                isDestructive: isDestructive
            ))

        case .deleteBranch:
            var existsOnRemote = false
            if case .deleteBranch(_, let onRemote) = details {
                existsOnRemote = onRemote
            }
            return .compactSheet(CompactConfirmation(
                title: title,
                paragraphs: message.components(separatedBy: "\n\n"),
                optionTitle: existsOnRemote ? "Delete it on the remote too" : nil,
                confirmButton: confirmButton,
                isDestructive: isDestructive
            ))

        default:
            return .alert(alertContent(numberFormat))
        }
    }

    /// The confirmation as an alert: the confirm button first (the default,
    /// red when destructive), then Cancel.
    @MainActor
    public func alertContent(_ numberFormat: NumberFormat) -> AlertContent {
        let confirmRole: AlertContent.Role = isDestructive ? .destructive : .primary
        return AlertContent(
            title: title,
            message: alertMessage(numberFormat),
            buttons: [AlertContent.Button(confirmButton, role: confirmRole), AlertContent.Button("Cancel", role: .cancel)],
            suppressionTitle: suppressionSetting == nil ? nil : AlertContent.doNotShowAgain,
            severity: isCritical ? .critical : .standard
        )
    }

    /// The answer for what the user chose in the alert: the checkbox, when
    /// confirmed, is "Do not show this message again".
    @MainActor
    func response(to alert: AlertResponse) -> ConfirmationResponse {
        let isConfirmed = alert.buttonIndex == 0
        return ConfirmationResponse(isConfirmed: isConfirmed, suppressesFutureConfirmations: isConfirmed && alert.isSuppressed)
    }

    /// The message with its list (files, authors): listed when there are at
    /// most ten, counted in the question otherwise.
    private func alertMessage(_ numberFormat: NumberFormat) -> String {
        switch details {
        case .files(let paths):
            switch kind {
            case .discardChanges, .discardAllChanges:
                return paths.count > AlertList.maximumItems ? message : AlertList.insert(paths, intoMessage: message, numberFormat: numberFormat)
            case .commitFilteredChanges:
                return message
            default:
                return AlertList.insert(paths, intoMessage: message, numberFormat: numberFormat)
            }
        case .authors(let usernames):
            return usernames.count > AlertList.maximumItems ? message : AlertList.insert(usernames, intoMessage: message, numberFormat: numberFormat)
        default:
            return message
        }
    }

    /// Discards, deletions, aborts, and replacing what's at the command line
    /// tool's path are destructive.
    private var isDestructive: Bool {
        switch kind {
        case .discardChanges, .discardAllChanges, .discardLines, .discardStash, .overwriteCommitMessage,
             .removeWorktree, .abortWithResolvedConflicts, .deleteBranch, .deleteRemoteBranch, .deleteTag,
             .removeRepository, .leaveCommitsBehind, .replaceCommandLineTool:
            true
        default:
            false
        }
    }

    /// Discards, deletions, and force pushes are critical.
    private var isCritical: Bool {
        switch kind {
        case .discardChanges, .discardAllChanges, .discardLines, .discardStash, .forcePush,
             .rewritePublishedCommits, .deleteBranch, .deleteRemoteBranch, .deleteTag, .removeWorktree:
            true
        default:
            false
        }
    }
}

/// A compact confirmation: its paragraphs and path, the option's checkbox
/// when it has one, then Cancel and the confirm button, the default.
public struct CompactConfirmationSheet: View {
    private let content: CompactConfirmation
    private let onAnswer: (ConfirmationResponse) -> Void
    @State private var isOptionSelected = false

    public init(_ content: CompactConfirmation, onAnswer: @escaping (ConfirmationResponse) -> Void) {
        self.content = content
        self.onAnswer = onAnswer
    }

    public var body: some View {
        SheetScaffold(content.title, width: Metrics.Sheet.compactWidth) {
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                ForEach(Array(content.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let path = content.path {
                    MonoChip(path, isSelectable: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let optionTitle = content.optionTitle {
                Toggle(optionTitle, isOn: $isOptionSelected)
                    .toggleStyle(.checkboxMark)
            }
        } buttons: {
            SheetButtons(
                content.confirmButton,
                confirmRole: content.isDestructive ? .destructive : nil,
                cancel: { onAnswer(.cancelled) },
                confirm: { onAnswer(ConfirmationResponse(isConfirmed: true, isOptionSelected: isOptionSelected)) }
            )
        }
    }
}

/// Shows the presenter's confirmations.
@MainActor
enum ConfirmationHost {
    static let sheetID = "espalier.confirmation"

    /// Shows `pending` and answers the presenter when the user chooses.
    static func present(_ pending: PendingConfirmation, in context: WindowContext) {
        let presenter = context.presenter
        let confirmation = pending.confirmation
        switch confirmation.presentation(context.app.preferences.numberFormat) {
        case .alert(let content):
            Task {
                let response = await context.modals.alert(content)
                presenter.respond(to: pending.id, with: confirmation.response(to: response))
            }
        case .compactSheet(let content):
            let modals = context.modals
            modals.presentSheet(id: sheetID, onDismiss: {
                presenter.respond(to: pending.id, with: .cancelled)
            }) {
                CompactConfirmationSheet(content) { response in
                    presenter.respond(to: pending.id, with: response)
                    modals.dismissSheet(id: sheetID)
                }
            }
        }
    }
}
