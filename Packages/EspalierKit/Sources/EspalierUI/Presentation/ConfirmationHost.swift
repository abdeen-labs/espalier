// How each of the state layer's 21 confirmations is shown. The copy is the
// state layer's (`Confirmation`); this file decides alert or compact sheet,
// button roles, severity, lists, and the suppression toggle.

import EspalierCore
import GitKit
import SwiftUI

/// How a confirmation is shown.
nonisolated public enum ConfirmationPresentation: Sendable, Equatable {
    case alert(AlertContent)
    /// A sheet for confirmations with a checkbox alerts can't hold.
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
    /// How the confirmation is shown.
    @MainActor
    public var presentation: ConfirmationPresentation {
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
                isDestructive: true
            ))

        case .deleteBranch:
            let paragraphs = message.components(separatedBy: "\n\n")
            var existsOnRemote = false
            if case .deleteBranch(_, let onRemote) = details {
                existsOnRemote = onRemote
            }
            return .compactSheet(CompactConfirmation(
                title: title,
                paragraphs: paragraphs,
                optionTitle: existsOnRemote ? "Delete it on the remote too" : nil,
                confirmButton: confirmButton,
                isDestructive: true
            ))

        default:
            return .alert(alertContent)
        }
    }

    /// The confirmation as an alert.
    @MainActor
    var alertContent: AlertContent {
        let confirmRole: AlertContent.Role = isDestructive ? .destructive : .primary
        return AlertContent(
            title: title,
            message: alertMessage,
            buttons: [AlertContent.Button(confirmButton, role: confirmRole), AlertContent.Button("Cancel", role: .cancel)],
            suppressionTitle: suppressionSetting == nil ? nil : AlertContent.doNotShowAgain,
            severity: isCritical ? .critical : .standard
        )
    }

    /// The message with its list (files, authors): listed when there are at
    /// most ten, counted in the question otherwise.
    private var alertMessage: String {
        switch details {
        case .files(let paths):
            switch kind {
            case .discardChanges, .discardAllChanges:
                return paths.count > AlertList.maximumItems ? message : AlertList.insert(paths, intoMessage: message)
            case .commitFilteredChanges:
                return message
            default:
                return AlertList.insert(paths, intoMessage: message)
            }
        case .authors(let usernames):
            return usernames.count > AlertList.maximumItems ? message : AlertList.insert(usernames, intoMessage: message)
        default:
            return message
        }
    }

    /// Discards, deletions, and aborts are destructive.
    private var isDestructive: Bool {
        switch kind {
        case .discardChanges, .discardAllChanges, .discardLines, .discardStash, .overwriteCommitMessage,
             .removeWorktree, .abortWithResolvedConflicts, .deleteBranch, .deleteRemoteBranch, .deleteTag,
             .removeRepository, .leaveCommitsBehind:
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

/// A compact confirmation: its paragraphs, an optional checkbox, Cancel and
/// the confirm button.
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
                    MonoChip(path)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let optionTitle = content.optionTitle {
                Toggle(optionTitle, isOn: $isOptionSelected)
                    .toggleStyle(.checkbox)
            }
        } buttons: {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) {
                onAnswer(.cancelled)
            }
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            Button(content.confirmButton, role: content.isDestructive ? .destructive : nil) {
                onAnswer(ConfirmationResponse(isConfirmed: true, isOptionSelected: isOptionSelected))
            }
            .buttonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
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
        switch pending.confirmation.presentation {
        case .alert(let content):
            Task {
                let response = await context.modals.alert(content)
                let isConfirmed = response.buttonIndex == 0
                presenter.respond(to: pending.id, with: ConfirmationResponse(
                    isConfirmed: isConfirmed,
                    suppressesFutureConfirmations: isConfirmed && response.isSuppressed
                ))
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
