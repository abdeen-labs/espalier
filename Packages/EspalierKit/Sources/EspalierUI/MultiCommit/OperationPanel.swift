// Ported in part from desktop/app/src/ui/multi-commit-operation/base-multi-commit-operation.tsx, dialog/conflicts-dialog.tsx, dialog/progress-dialog.tsx, and ui/changes/continue-rebase.tsx
//
// The operation panel: a bar across the top of Changes while an operation
// runs, waits on conflicts, or a stash restore conflicted, with the
// operation, the commit it stopped at and the resolved count (or its
// progress), Resolve with AI, and Abort (quiet). What finishes the
// operation is in the commit form's place (OperationSlot.swift): Commit
// Merge under the merge's message, or Continue.

import AIKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the operation panel shows, and what the commit form's place needs
/// to finish the operation.
nonisolated public struct OperationPanelContent: Sendable, Equatable {
    /// The panel's state.
    public enum State: Sendable, Equatable {
        /// An operation runs: "Commit 2 of 5 · summary", and its progress.
        case running(detail: String?, progress: Double?)
        /// Waiting on conflicts: "1 of 2 conflicted files has been
        /// resolved."
        case conflicts(summary: String)
        /// A rebase git was interrupted between commits.
        case interrupted(message: String)
        /// A stash restore conflicted (no operation to continue or abort).
        case stashConflicts(message: String)
        /// A `git am` or a bisect, which only git can continue or abort.
        case unsupported(message: String)
    }

    public var title: String
    public var state: State
    /// "Abort Rebase"; nil when there's nothing to abort.
    public var abortTitle: String?
    /// "Continue Rebase", "Commit Merge": the commit form's button while the
    /// operation waits; nil when there's nothing to continue.
    public var continueTitle: String?
    public var canContinue: Bool
    /// Continue's tooltip while it's disabled.
    public var continueHelp: String?
    /// Whether "Untracked files will be excluded" shows under Continue (a
    /// rebase with untracked files).
    public var notesUntrackedFiles: Bool
    /// Whether Resolve with AI shows (AI is on and files need the user).
    public var showsResolveWithAI: Bool
    /// Whether it can start now (no round runs).
    public var canResolveWithAI: Bool
    /// Whether no conflicted file needs the user any more.
    public var isResolved: Bool
    /// Whether Open in Terminal shows (an operation only git can finish).
    public var opensTerminal: Bool
    /// Which commit a rebase or cherry-pick stopped at: "Stopped at commit
    /// 2 of 4", first on the line under the title.
    public var stoppedAt: String?

    public init(
        title: String,
        state: State,
        abortTitle: String? = nil,
        continueTitle: String? = nil,
        canContinue: Bool = false,
        continueHelp: String? = nil,
        notesUntrackedFiles: Bool = false,
        showsResolveWithAI: Bool = false,
        canResolveWithAI: Bool = false,
        isResolved: Bool = false,
        opensTerminal: Bool = false,
        stoppedAt: String? = nil
    ) {
        self.title = title
        self.state = state
        self.abortTitle = abortTitle
        self.continueTitle = continueTitle
        self.canContinue = canContinue
        self.continueHelp = continueHelp
        self.notesUntrackedFiles = notesUntrackedFiles
        self.showsResolveWithAI = showsResolveWithAI
        self.canResolveWithAI = canResolveWithAI
        self.isResolved = isResolved
        self.opensTerminal = opensTerminal
        self.stoppedAt = stoppedAt
    }

    /// What a conflicted file still needing the user says about resolving
    /// it, as its tooltip.
    public static let hint = "Resolve in your editor or in Terminal; Espalier picks up your changes as you save."

    /// Continue's tooltip while files need the user.
    public static let continueDisabledHelp = "Resolve all conflicts before continuing"

    /// Commit Merge's tooltip while the merge's summary is empty (the commit
    /// button's).
    public static let summaryRequiredHelp = "Enter a summary to commit"

    /// "2 conflicted files", "1 of 2 conflicted files has been resolved.",
    /// or "All conflicted files have been resolved."
    public static func summary(resolved: Int, total: Int) -> String {
        if resolved == 0 {
            return total == 1 ? "1 conflicted file" : "\(total) conflicted files"
        }
        if resolved >= total {
            return "All conflicted files have been resolved."
        }
        return "\(resolved) of \(total) conflicted files \(resolved == 1 ? "has" : "have") been resolved."
    }

    /// The operation's display name ("Rebase", "Cherry-pick", "Revert").
    static func name(of operation: MultiCommitOperation) -> String {
        if case .revert = operation.detail {
            return "Revert"
        }
        return operation.kind.rawValue
    }

    /// The display name of the operation conflicts belong to, when there's
    /// no operation to name it.
    static func name(of conflictState: ConflictState) -> String {
        switch conflictState {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    /// The panel for an operation waiting on conflicts.
    ///
    /// - Parameters:
    ///   - mergeMessage: A merge's message, once loaded: Commit Merge waits
    ///     for a summary.
    ///   - step: Which commit a rebase or cherry-pick stopped at
    ///     (`operations.stoppedStep`): with more than one, the line under
    ///     the title says which.
    public static func conflicts(
        operation: String,
        isMerge: Bool,
        resolved: Int,
        total: Int,
        unresolved: Int,
        isContinuing: Bool,
        hasUntrackedFiles: Bool,
        isRebaseFamily: Bool,
        showsResolveWithAI: Bool,
        canResolveWithAI: Bool,
        mergeMessage: MergeMessage? = nil,
        step: OperationStep? = nil
    ) -> OperationPanelContent {
        let lacksSummary = isMerge && (mergeMessage.map { $0.summary.unicodeScalars.allSatisfy(JSCompat.isWhitespace) } ?? false)
        let stoppedAt = step.flatMap { $0.total > 1 ? "Stopped at commit \($0.position) of \($0.total)" : nil }
        return OperationPanelContent(
            title: unresolved > 0 ? "Resolve conflicts before \(operation)" : "All conflicts resolved",
            state: .conflicts(summary: summary(resolved: resolved, total: total)),
            abortTitle: "Abort \(operation)",
            continueTitle: isMerge ? "Commit Merge" : "Continue \(operation)",
            canContinue: unresolved == 0 && !isContinuing && !lacksSummary,
            continueHelp: unresolved > 0 ? continueDisabledHelp : (lacksSummary ? summaryRequiredHelp : nil),
            notesUntrackedFiles: isRebaseFamily && hasUntrackedFiles,
            showsResolveWithAI: showsResolveWithAI && unresolved > 0,
            canResolveWithAI: canResolveWithAI,
            isResolved: unresolved == 0,
            stoppedAt: stoppedAt
        )
    }

    /// The panel for a repository, or nil when nothing runs, nothing waits
    /// on conflicts, and no stash restore conflicted.
    @MainActor
    public static func make(_ repository: RepositoryModel, aiEnabled: Bool) -> OperationPanelContent? {
        let operations = repository.operations
        let files = repository.changes.workingDirectory.files
        let unmerged = files.filter { $0.status.kind == .conflicted }
        let unresolvedCount = operations.unresolvedFiles.count
        let hasUntracked = files.contains { $0.status.kind == .untracked }

        if let current = operations.current {
            let name = name(of: current)
            switch current.phase {
            case .running(let progress), .continuing(let progress):
                return running(name: name, progress: progress)
            case .interrupted:
                return OperationPanelContent(
                    title: "\(name) interrupted",
                    state: .interrupted(message: current.interruptedMessage),
                    abortTitle: "Abort \(name)",
                    continueTitle: "Continue \(name)",
                    canContinue: operations.canContinue
                )
            case .conflicted:
                let isRebaseFamily = current.kind == .rebase || current.kind == .squash || current.kind == .reorder
                return conflicts(
                    operation: name,
                    isMerge: current.kind == .merge,
                    resolved: max(unmerged.count - unresolvedCount, 0),
                    total: unmerged.count,
                    unresolved: unresolvedCount,
                    isContinuing: false,
                    hasUntrackedFiles: hasUntracked,
                    isRebaseFamily: isRebaseFamily,
                    showsResolveWithAI: aiEnabled,
                    canResolveWithAI: repository.ai.canResolveConflicts,
                    mergeMessage: operations.mergeMessage,
                    step: operations.stoppedStep
                )
            }
        }
        if let conflictState = operations.conflictState {
            let isMerge: Bool = if case .merge = conflictState { true } else { false }
            let isRebase: Bool = if case .rebase = conflictState { true } else { false }
            return conflicts(
                operation: name(of: conflictState),
                isMerge: isMerge,
                resolved: max(unmerged.count - unresolvedCount, 0),
                total: unmerged.count,
                unresolved: unresolvedCount,
                isContinuing: false,
                hasUntrackedFiles: hasUntracked,
                isRebaseFamily: isRebase,
                showsResolveWithAI: aiEnabled,
                canResolveWithAI: repository.ai.canResolveConflicts,
                mergeMessage: operations.mergeMessage,
                step: operations.stoppedStep
            )
        }
        if let local = repository.localOperation, let name = runningName(of: local.kind) {
            switch local.progress {
            case .multiCommitOperation(let progress)?:
                return running(name: name, progress: progress)
            case .revert(let progress)?:
                return OperationPanelContent(title: "\(name) in progress", state: .running(detail: progress.description, progress: progress.value))
            default:
                return OperationPanelContent(title: "\(name) in progress", state: .running(detail: nil, progress: nil))
            }
        }
        if let restore = repository.stash.conflictedRestore {
            return OperationPanelContent(
                title: "Resolve conflicts",
                state: .stashConflicts(message: "Restoring the stash on \(restore.entry.branchName) caused conflicts. Resolve them to finish; the stash is kept until you do.")
            )
        }
        if let inProgress = repository.gitState.inProgress, let title = inProgress.unsupportedTitle,
           let message = inProgress.unsupportedMessage {
            return OperationPanelContent(title: title, state: .unsupported(message: message), opensTerminal: true)
        }
        return nil
    }

    private static func running(name: String, progress: MultiCommitOperationProgress) -> OperationPanelContent {
        var detail: String?
        if progress.totalCommitCount > 0 {
            detail = "Commit \(progress.position) of \(progress.totalCommitCount)"
            if !progress.currentCommitSummary.isEmpty {
                detail! += " · \(progress.currentCommitSummary)"
            }
        }
        return OperationPanelContent(
            title: "\(name) in progress",
            state: .running(detail: detail, progress: progress.value)
        )
    }

    /// The display name of a running multi-commit operation.
    static func runningName(of kind: OperationKind) -> String? {
        switch kind {
        case .merge, .finishMerge: "Merge"
        case .rebase, .continueRebase: "Rebase"
        case .cherryPick, .continueCherryPick: "Cherry-pick"
        case .squash: "Squash"
        case .reorder: "Reorder"
        case .revert, .continueRevert: "Revert"
        default: nil
        }
    }
}

/// The operation panel for a repository: the bar across the top of
/// Changes.
public struct OperationPanel: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    /// Whether the panel has anything to show for `repository`.
    @MainActor
    public static func isShown(for repository: RepositoryModel) -> Bool {
        OperationPanelContent.make(repository, aiEnabled: false) != nil
    }

    public var body: some View {
        let aiEnabled = context.app.ai.isEnabled
        if let content = OperationPanelContent.make(repository, aiEnabled: aiEnabled) {
            OperationPanelView(
                content: content,
                aiError: AIConflictFlow.state(in: context).startError(for: repository.id),
                onAbort: abort,
                onOpenTerminal: { context.actions.perform(.openInTerminal(path: nil)) },
                onResolveWithAI: { AIConflictFlow.start(in: context, repository: repository) }
            )
            .popoverCard(item: aiGateBinding, title: "Resolve Conflicts with AI") { gate in
                AIGatePopover(gate: gate, repository: repository)
                    .windowEnvironment(context)
            }
        }
    }

    private var aiGateBinding: Binding<AIConflictGate?> {
        let state = AIConflictFlow.state(in: context)
        return Binding(
            get: { state.gate?.repositoryID == repository.id ? state.gate : nil },
            set: { state.gate = $0 }
        )
    }

    private func abort() {
        let repository = repository
        Task { [weak context] in
            guard let context else {
                return
            }
            await MultiCommitActions.abortOperation(in: context, repository: repository)
        }
    }
}

/// The bar's look, value-driven: the state's glyph, the title and the line
/// under it, a running operation's progress, and the buttons.
struct OperationPanelView: View {
    let content: OperationPanelContent
    var aiError: String?
    var onAbort: () -> Void = {}
    var onOpenTerminal: () -> Void = {}
    var onResolveWithAI: () -> Void = {}

    var body: some View {
        StatusBar(tone: tone, title: content.title, subtitle: subtitle, help: subtitleHelp) {
            glyph
        } trailing: {
            progress
            buttons
        }
    }

    /// Neutral while work runs, the add color once nothing's left to
    /// resolve, the modified color while anything waits on the user.
    private var tone: StatusBarTone {
        switch content.state {
        case .running: .neutral
        case .conflicts: content.isResolved ? .ready : .attention
        case .interrupted, .stashConflicts, .unsupported: .attention
        }
    }

    /// A spinner while work runs; else the warning, which turns into the
    /// check once nothing's left to resolve (a symbol replace).
    @ViewBuilder
    private var glyph: some View {
        if case .running = content.state {
            ArcProgress(.small)
                .accessibilityHidden(true)
        } else {
            let isResolved: Bool = if case .conflicts = content.state { content.isResolved } else { false }
            Image(systemName: isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(Color(espalier: isResolved ? Palette.success : Palette.warningMark))
                .contentTransition(.symbolEffect(.replace))
                .motion(Motion.arrive, value: isResolved)
                .accessibilityLabel("Warning")
                .accessibilityHidden(isResolved)
        }
    }

    /// The line under the title: the commit it stopped at and the files
    /// left, a running operation's commit, or the state's message; AI's
    /// error in its place when Resolve with AI failed.
    private var subtitle: Text? {
        if let aiError {
            return Text(aiError).foregroundStyle(Color(espalier: Palette.error))
        }
        return subtitleText.map { Text($0) }
    }

    private var subtitleHelp: String? {
        aiError ?? subtitleText
    }

    private var subtitleText: String? {
        var parts: [String] = []
        switch content.state {
        case .running(let detail, _):
            if let detail {
                parts.append(detail)
            }
        case .conflicts(let summary):
            if let stoppedAt = content.stoppedAt {
                parts.append(stoppedAt)
            }
            parts.append(summary)
        case .interrupted(let message), .stashConflicts(let message), .unsupported(let message):
            parts.append(message)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A running operation's progress bar, when it knows how far it got.
    @ViewBuilder
    private var progress: some View {
        if case .running(_, let progress?) = content.state {
            CapsuleProgressBar(value: progress)
                .frame(width: Metrics.OperationPanel.progressWidth)
                .padding(.trailing, Metrics.grid)
                .accessibilityLabel("Progress")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if content.showsResolveWithAI {
            Button(action: onResolveWithAI) {
                Label("Resolve with AI", systemImage: "sparkles")
            }
            .buttonStyle(.quiet)
            .disabled(!content.canResolveWithAI)
        }
        if content.opensTerminal {
            Button("Open in Terminal", action: onOpenTerminal)
                .buttonStyle(.quiet)
        }
        if let abortTitle = content.abortTitle {
            Button(abortTitle, action: onAbort)
                .buttonStyle(.quiet)
        }
    }
}

extension Metrics {
    /// The operation panel.
    enum OperationPanel {
        /// A running operation's progress bar.
        static let progressWidth: CGFloat = 120
    }
}
