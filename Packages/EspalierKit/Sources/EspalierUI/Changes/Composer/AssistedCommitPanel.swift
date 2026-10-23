// Committing with AI in the composer: the Manual | Assisted switch above
// the card, and, in Assisted, the card's status in place of the message
// fields (which keep the draft, out of sight): what the run will do, what
// it's doing (with Cancel while it can stop), and a failure with what to do
// about it (Retry Undo, Retry Push, Open AI Settings…, or Dismiss).

import AIKit
import EspalierCore
import GitKit
import SwiftUI

/// What the assisted card's status shows.
nonisolated public struct AssistedCommitContent: Sendable, Equatable {
    /// What can be done about a failure.
    public enum Recovery: Sendable, Equatable {
        /// Nothing was kept: the next commit tries again.
        case dismiss
        /// Undoing the run didn't finish.
        case retryUndo
        /// The commits were made; pushing them failed.
        case retryPush
        /// The AI setup is at fault.
        case openSettings
    }

    public enum Status: Sendable, Equatable {
        /// Ready to plan with `model`.
        case ready(model: String?)
        /// No AI provider is set up.
        case needsProvider
        /// Several models are set up and none is chosen.
        case needsModelChoice
        case running(AssistedCommitPhase, canCancel: Bool)
        case failed(message: String, recovery: Recovery)
    }

    public var status: Status

    public init(status: Status) {
        self.status = status
    }

    /// The status's first line.
    public var title: String {
        switch status {
        case .ready, .needsProvider, .needsModelChoice:
            return "Commit with AI"
        case .running(let phase, _):
            switch phase {
            case .preparing: return "Reading the selected changes…"
            case .planning: return "Planning commits…"
            case .summarizing: return "Writing one commit message…"
            case .validating: return "Checking the plan…"
            case .committing(let index, let total, _): return "Making commit \(index + 1) of \(total)…"
            case .finishing: return "Finishing…"
            case .rollingBack: return "Undoing the assisted commit…"
            case .pushing: return "Pushing…"
            }
        case .failed(_, let recovery):
            switch recovery {
            case .retryUndo: return "Couldn't undo the assisted commit"
            case .retryPush: return "Committed, but couldn't push"
            case .dismiss, .openSettings: return "Couldn't commit with AI"
            }
        }
    }

    /// The status's second line.
    public var detail: String {
        switch status {
        case .ready(let model):
            let planner = model ?? "The model"
            return "\(planner) splits the selected changes into focused commits and writes their messages. Nothing is committed until every commit checks out."
        case .needsProvider:
            return "Add an AI provider to plan commits with your own API key."
        case .needsModelChoice:
            return "Choose the model that plans commits."
        case .running(let phase, _):
            switch phase {
            case .preparing: return "The changes are frozen as they are now."
            case .planning(let changes): return "Asking the model to group \(changes) \(changes == 1 ? "change" : "changes")."
            case .summarizing: return "The planned commits can't be made in that order, so they become one."
            case .validating: return "Every commit is checked before any is made."
            case .committing(_, _, let title): return title
            case .finishing: return "Checking the commits before keeping them."
            case .rollingBack: return "Taking the new commits off the branch. Your files stay as they are."
            case .pushing: return "The commits are made."
            }
        case .failed(let message, _):
            return message
        }
    }

    /// Whether a run is going.
    public var isRunning: Bool {
        if case .running = status { true } else { false }
    }
}

extension AssistedCommitContent.Status {
    /// Whether undoing the last run needs retrying before another can run.
    var isUndoWaiting: Bool {
        if case .failed(_, .retryUndo) = self { true } else { false }
    }
}

extension AssistedCommitContent {
    /// The assisted card for a repository, from its run and the commit
    /// message feature's AI status.
    @MainActor
    public static func make(_ repository: RepositoryModel, app: AppModel) -> AssistedCommitContent {
        switch repository.commit.assisted {
        case .running(let phase):
            let canStop = repository.localOperation?.kind == .commit
            let canCancel = canStop && phase != .finishing && phase != .rollingBack && phase != .pushing
            return AssistedCommitContent(status: .running(phase, canCancel: canCancel))
        case .failed(let error):
            return AssistedCommitContent(status: .failed(message: message(error), recovery: isSetupFailure(error) ? .openSettings : .dismiss))
        case .recoveryNeeded(let error):
            return AssistedCommitContent(status: .failed(message: message(error), recovery: .retryUndo))
        case .pushFailed(let error):
            return AssistedCommitContent(status: .failed(message: message(error), recovery: .retryPush))
        case .idle:
            break
        }
        switch app.ai.status(for: .commitMessageGeneration) {
        case .needsProvider:
            return AssistedCommitContent(status: .needsProvider)
        case .needsModelChoice:
            return AssistedCommitContent(status: .needsModelChoice)
        case .disabled, .needsConsent, .ready:
            return AssistedCommitContent(status: .ready(model: app.ai.resolvedModel(for: .commitMessageGeneration)?.model.name))
        }
    }

    private static func message(_ error: OperationError) -> String {
        if case .ai(let failure) = error.reason {
            return failure.message
        }
        return error.message
    }

    private static func isSetupFailure(_ error: OperationError) -> Bool {
        switch error.reason {
        case .ai(.noProvider), .ai(.modelSelectionRequired), .ai(.modelUnavailable), .ai(.disabled):
            return true
        default:
            return error.recoveries.contains { if case .openSettings(.ai) = $0 { true } else { false } }
        }
    }
}

/// What the assisted card's buttons do.
struct AssistedCommitActions {
    var cancel: () -> Void = {}
    var retryUndo: () -> Void = {}
    var retryPush: () -> Void = {}
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    var chooseModel: () -> Void = {}
}

/// The assisted card's status: the sparkles (or the arc while a run goes,
/// or the error's mark), the title and its detail, and the status's button.
struct AssistedCommitStatusView: View {
    let content: AssistedCommitContent
    let actions: AssistedCommitActions

    init(_ content: AssistedCommitContent, actions: AssistedCommitActions) {
        self.content = content
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            mark
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(isError ? Color(espalier: Palette.error) : Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(content.detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            button
        }
        .accessibilityElement(children: .contain)
    }

    private var isError: Bool {
        if case .failed = content.status { true } else { false }
    }

    @ViewBuilder
    private var mark: some View {
        switch content.status {
        case .running:
            ArcProgress(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityHidden(true)
        case .ready, .needsProvider, .needsModelChoice:
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch content.status {
        case .running(_, let canCancel):
            if canCancel {
                Button("Cancel", action: actions.cancel)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            }
        case .needsProvider:
            Button("Open AI Settings…", action: actions.openSettings)
                .buttonStyle(.quiet)
                .controlSize(.small)
        case .needsModelChoice:
            Button("Choose Model…", action: actions.chooseModel)
                .buttonStyle(.quiet)
                .controlSize(.small)
        case .failed(_, let recovery):
            switch recovery {
            case .retryUndo:
                Button("Retry Undo", action: actions.retryUndo)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            case .retryPush:
                HStack(spacing: Metrics.insetSmall) {
                    Button("Dismiss", action: actions.dismiss)
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                    Button("Retry Push", action: actions.retryPush)
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                }
            case .openSettings:
                Button("Open AI Settings…", action: actions.openSettings)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            case .dismiss:
                Button("Dismiss", action: actions.dismiss)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            }
        case .ready:
            EmptyView()
        }
    }
}

/// The Manual | Assisted switch above the composer's card.
struct CommitModeSwitch: View {
    let mode: CommitMode
    let onChange: (CommitMode) -> Void

    var body: some View {
        CapsuleSegmentedControl(
            "Commit Mode",
            selection: Binding(get: { mode }, set: { onChange($0) }),
            segments: [
                CapsuleSegment("Manual", systemImage: "pencil", value: CommitMode.manual),
                CapsuleSegment("Assisted", systemImage: "sparkles", value: CommitMode.assisted),
            ],
            fillsWidth: true
        )
        .tooltip(mode == .assisted ? "Commit with AI: the selected changes become focused commits" : "Commit with the message you write")
    }
}
