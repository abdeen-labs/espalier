// The Changes place: the Changes column (the header, the changed files,
// conflicted ones with their state and buttons, the "Stashed Changes" row,
// and the composer, which commits a waiting merge, or Continue while a
// rebase, cherry-pick, or revert waits) under the operation panel while an
// operation runs or waits on conflicts, and on the right the selected
// file's diff, several files' actions, or "No Local Changes" and
// Suggestions when there are no changes. The toolbar's search field is the
// list's filter text.

import EspalierCore
import GitKit
import SwiftUI

/// The Changes place: the Changes column and the diff.
public struct ChangesScreen: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    /// The operation panel's 300 ms rule.
    @State private var operationPresence = OperationPanelPresence()

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let demand = OperationPanelPresence.demand(for: repository)
        let showsPanel = operationPresence.isShown(for: demand)
        SplitView(.changes) {
            ChangesColumn(repository: repository)
        } trailing: {
            ChangesDetail(repository: repository)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The operation's bar, across the place. It grows in over 0.22 s
            // and leaves over 0.15 s, Changes moving with it, and a running
            // operation shows it only past 300 ms.
            if showsPanel {
                // A card of its own above the place's in the floating
                // layout.
                OperationPanel(repository: repository)
                    .paneCard(margins: EdgeInsets(top: 0, leading: 0, bottom: PaneCards.frameGap, trailing: 0))
                    .barTransition()
            }
        }
        .barMotion(showsPanel)
        .environment(\.showsOperationPanel, showsPanel)
        .onChange(of: demand, initial: true) {
            operationPresence.update(demand, scheduler: context.app.environment.scheduler)
        }
        .onChange(of: context.state.searchText, initial: true) {
            // The toolbar's search field is the filter's text (the Mail
            // pattern).
            let text = context.state.searchText
            if repository.changes.filter.text != text {
                repository.changes.filter.text = text
            }
        }
        .onAppear {
            // The stash is a place of its own; Changes shows the working
            // directory.
            repository.stash.hide()
        }
        // Choosing another repository shows its Changes at once: the place
        // is kept, so its bars and counts would otherwise animate.
        .motionScope(AnyHashable(ObjectIdentifier(repository)))
    }
}

/// The Changes column: the header, the files, and the composer; without
/// changes, the header ("0 changed files") over the empty list. The
/// footer's bars (the hidden-changes note, the Stashed Changes row, the
/// amend banner, the composer or Continue) grow in over 0.22 s and leave
/// over 0.15 s, the files moving with them: the motion is set here, over
/// the whole column, so the list above moves too.
struct ChangesColumn: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.showsOperationPanel) private var showsOperationPanel
    @Environment(\.motion) private var motion

    var body: some View {
        let hasFiles = !repository.changes.workingDirectory.files.isEmpty
        let controller = ChangesController(context: context, repository: repository)
        let footer = ChangesFooterLayout.make(repository, showsOperationPanel: showsOperationPanel)
        FileList(repository: repository)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ChangesHeader(
                    ChangesHeaderContent.make(repository, numberFormat: context.app.preferences.numberFormat),
                    onIncludeAll: { include in
                        repository.changes.setVisibleFilesIncluded(include)
                    },
                    onFilterChange: { filter in
                        repository.changes.filter = filter
                    },
                    onClearFilters: controller.clearFilters
                )
                .contextMenuCard { [context] in
                    ChangesHeaderMenu.content(repository: repository, context: context)
                }
                Hairline()
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ChangesFooter(repository: repository, layout: footer)
        }
        .barMotion(footer.showsHiddenNote)
        .barMotion(footer.stashCount > 0)
        .barMotion(footer.isAmending)
        .motion(footer.bottom == .none ? Motion.leave : Motion.arrive, value: footer.bottom)
        // The Last Commit row grows in after a commit, unless that commit
        // took every file: committing everything shows the empty state
        // with no motion.
        .animation(hasFiles ? motion.animation(footer.showsLastCommit ? Motion.arrive : Motion.leave) : nil, value: footer.showsLastCommit)
    }
}

/// What the Changes column's footer shows: the keys of its motion.
struct ChangesFooterLayout: Equatable {
    /// What the commit form's place shows.
    enum Bottom: Equatable {
        /// The composer, for the user's commit.
        case composer
        /// The composer with the merge's message, for Commit Merge.
        case merge
        /// Continue, for a rebase, cherry-pick, or revert waiting on the
        /// user.
        case continueOperation
        /// Nothing: an operation runs, a stash restore conflicted, or only
        /// git can finish what's in progress.
        case none
    }

    var showsHiddenNote: Bool
    /// How many stashes the current branch has: the "Stashed Changes" row
    /// shows when it has any.
    var stashCount: Int
    var bottom: Bottom
    var isAmending: Bool
    /// The composer's Last Commit row (Undo), after a commit.
    var showsLastCommit: Bool

    /// The footer for `repository`; a fast operation never takes the
    /// composer away (the operation panel's 300 ms rule, which Changes
    /// passes as `showsOperationPanel`).
    @MainActor
    static func make(_ repository: RepositoryModel, showsOperationPanel: Bool?) -> ChangesFooterLayout {
        let bottom: Bottom
        switch OperationSlotContent.make(repository)?.kind {
        case .merge?:
            bottom = .merge
        case .continueOperation?:
            bottom = .continueOperation
        case nil:
            let hasOperation = OperationCapsuleContent.make(repository) != nil && showsOperationPanel != false
            bottom = hasOperation ? .none : .composer
        }
        // `LastCommitContent.make`'s rule, without reading what the row
        // shows.
        let commit = repository.commit
        let hasLastCommit = commit.mostRecentLocalCommit.map { $0.sha == commit.undoableCommitSHA } ?? false
        return ChangesFooterLayout(
            showsHiddenNote: !repository.changes.includedFilesHiddenByFilter.isEmpty,
            stashCount: repository.stash.currentEntries.count,
            bottom: bottom,
            isAmending: bottom == .composer && commit.amending != nil,
            showsLastCommit: bottom == .composer && hasLastCommit
        )
    }
}

/// The header's context menu: Discard All Changes… and Stash All Changes,
/// as the Repository menu has them; none while a commit runs or a rebase
/// waits on conflicts.
enum ChangesHeaderMenu {
    @MenuBuilder
    static func content(repository: RepositoryModel, context: WindowContext) -> MenuContent {
        let controller = ChangesController(context: context, repository: repository)
        if !controller.isCommitting, !controller.isRebaseConflicts {
            for item in FileContextMenuContent.headerItems(actions: context.actions) {
                MenuAction(item.title) {
                    context.actions.perform(item.action)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}

/// Under the files: the hidden-changes note, the "Stashed Changes" row, and
/// the composer (Commit Merge's too) or Continue. Each comes and goes as a
/// bar does (the column sets the motion); the composer stays from a merge's
/// conflicts through its commit, its fields and button changing in place.
struct ChangesFooter: View {
    let repository: RepositoryModel
    let layout: ChangesFooterLayout
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = repository.changes
        let controller = ChangesController(context: context, repository: repository)
        VStack(spacing: 0) {
            if layout.showsHiddenNote {
                VStack(spacing: 0) {
                    Hairline()
                    HiddenChangesNote(
                        count: changes.includedFilesHiddenByFilter.count,
                        numberFormat: context.app.preferences.numberFormat,
                        onShow: controller.showIncludedFiles
                    )
                }
                .barTransition()
            }
            if layout.stashCount > 0 {
                VStack(spacing: 0) {
                    Hairline()
                    StashedChangesRow(count: layout.stashCount) {
                        context.actions.perform(.toggleStashedChanges)
                    }
                }
                .barTransition()
            }
            switch layout.bottom {
            case .composer, .merge:
                VStack(spacing: 0) {
                    Hairline()
                    Composer(repository: repository)
                }
                .barTransition()
            case .continueOperation:
                VStack(spacing: 0) {
                    Hairline()
                    ContinueOperation(repository: repository)
                }
                .barTransition()
            case .none:
                EmptyView()
            }
        }
    }
}

/// The right side: the diff, several files' actions, or Suggestions.
struct ChangesDetail: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = repository.changes
        let controller = ChangesController(context: context, repository: repository)
        switch ChangesDetailKind.make(repository) {
        case .suggestions:
            NoChangesSuggestions(
                SuggestionsContent.make(repository, app: context.app, actions: context.actions),
                perform: { action in
                    context.actions.perform(action.actionID)
                },
                onChoosePullRequestAction: { choice in
                    context.app.preferences.pullRequestSuggestedNextAction = choice
                },
                onOpenIntegrationSettings: {
                    context.actions.perform(.openSettings(.integrations))
                }
            )
        case .multiple(let count):
            MultipleSelectionView(
                MultipleSelectionContent(
                    title: MultipleSelectionContent.title(count: count, numberFormat: context.app.preferences.numberFormat),
                    canChangeInclusion: !controller.isCommitting && !controller.isRebaseConflicts,
                    canDiscard: !controller.isCommitting && controller.canDiscard(controller.selectedFiles)
                ),
                onInclude: { changes.setIncluded(controller.selectedIDs, true) },
                onExclude: { changes.setIncluded(controller.selectedIDs, false) },
                onDiscard: { controller.discard(controller.selectedFiles) }
            )
        case .diff(let file):
            let isConflicted = file.status.kind == .conflicted
            // Staging goes through the changes model (the gutter's lines,
            // hunks, and discarded lines), which knows when lines can't be
            // selected (a conflicted file, a rebase's conflicts).
            DiffContainer(
                changes.diff,
                file: DiffFileInfo(file),
                context: isConflicted ? .conflict : .changes,
                staging: DiffStaging(changes: changes)
            )
        case .none:
            PlaceholderNote("Select a file to see its changes")
        }
    }
}

/// What the right side shows.
enum ChangesDetailKind: Equatable {
    /// No local changes: Suggestions.
    case suggestions
    /// Several files are selected.
    case multiple(count: Int)
    /// One file is selected: its diff.
    case diff(WorkingDirectoryFileChange)
    /// No file is selected.
    case none

    @MainActor
    static func make(_ repository: RepositoryModel) -> ChangesDetailKind {
        let changes = repository.changes
        guard !changes.workingDirectory.files.isEmpty else {
            return .suggestions
        }
        guard case .workingDirectory(let ids) = changes.selection, !ids.isEmpty else {
            return .none
        }
        guard ids.count == 1 else {
            return .multiple(count: ids.count)
        }
        return changes.workingDirectory.findFileWithID(ids[0]).map(ChangesDetailKind.diff) ?? .none
    }
}
