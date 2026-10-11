// The header over History's list: Simple | Graph, then in Graph mode the
// scope pop-up and the commit count, in Simple mode the branch shown; and
// during a search its status (HistorySearch.swift).

import EspalierCore
import GitKit
import SwiftUI

extension Metrics {
    /// The compact header row a History column starts with, and the inset
    /// of a commit's details, which line up with it.
    enum HistoryHeader {
        static let height: CGFloat = PaneHeader.height
        static let horizontalPadding: CGFloat = Metrics.insetLarge
        /// Between the header's controls.
        static let spacing: CGFloat = 10
    }
}

/// What the history's header shows.
nonisolated struct HistoryHeaderContent: Sendable, Equatable {
    /// Simple or Graph.
    var style: HistoryStyle = .graph
    var scope: HistoryScope
    /// "1,204 commits", or "1,200+ commits" while older ones aren't loaded.
    var count: String
    /// The branch the simple list follows (nil on a detached HEAD).
    var branchName: String?
    /// The search's status, while there is a query.
    var search: HistorySearchStatusContent?

    /// The count for the loaded commits: the total when it's known.
    static func count(loaded: Int, total: Int?, isComplete: Bool) -> String {
        if let total {
            return total == 1 ? "1 commit" : "\(formatCount(total)) commits"
        }
        if isComplete || loaded == 0 {
            switch loaded {
            case 0: return "No commits"
            case 1: return "1 commit"
            default: return "\(formatCount(loaded)) commits"
            }
        }
        return "\(formatCount(loaded))+ commits"
    }
}

/// The header over the list.
struct HistoryHeader: View {
    let content: HistoryHeaderContent
    var setStyle: (HistoryStyle) -> Void = { _ in }
    var setScope: (HistoryScope) -> Void = { _ in }
    var search = HistorySearchActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.HistoryHeader.spacing) {
                CapsuleSegmentedControl(
                    "History Style",
                    selection: Binding(get: { content.style }, set: { setStyle($0) }),
                    segments: [
                        CapsuleSegment(HistoryStyle.simple.title, systemImage: "list.bullet", value: .simple),
                        CapsuleSegment(HistoryStyle.graph.title, systemImage: "point.3.connected.trianglepath.dotted", value: .graph),
                    ]
                )
                .fixedSize()
                .tooltip("Show the current branch simply, or every branch as a graph")
                switch content.style {
                case .graph:
                    scopePicker
                    Spacer(minLength: 0)
                    if content.search == nil {
                        // Shown whole or not at all: a narrow list leaves
                        // the room to the scope.
                        ViewThatFits(in: .horizontal) {
                            Text(content.count)
                                .font(Typography.secondaryCount)
                                .foregroundStyle(.text3)
                                .lineLimit(1)
                                .fixedSize()
                            Color.clear
                                .frame(width: 0, height: 0)
                        }
                    }
                case .simple:
                    if let branch = content.branchName {
                        BranchNameLabel(name: branch)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: Metrics.HistoryHeader.height)
            if let status = content.search {
                HistorySearchStatus(content: status, actions: search)
                    .padding(.bottom, Metrics.insetSmall)
            }
        }
        .padding(.horizontal, Metrics.HistoryHeader.horizontalPadding)
    }

    /// The scope pop-up: a small quiet capsule with the scope's name and the
    /// capsule menus' up-and-down chevron.
    private var scopePicker: some View {
        MenuOpeningButton(kind: .popUp, accessibilityLabel: "Branches Shown", accessibilityValue: content.scope.title, menu: { [content, setScope] in
            MenuContent {
                MenuPicker(selection: Binding(get: { content.scope }, set: { setScope($0) })) {
                    for scope in HistoryScope.allCases {
                        MenuChoice(scope.title, value: scope)
                    }
                }
            }
        }) {
            HStack(spacing: Metrics.CapsuleMenu.chevronSpacing) {
                Text(content.scope.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .semibold))
                    .foregroundStyle(.text3)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.quiet)
        .controlSize(.small)
        .fixedSize()
        .tooltip("Which branches the history shows")
    }
}

/// A branch's name in History's headers: the branch symbol, then the name
/// (13 semibold), its middle cut when it's long.
struct BranchNameLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: Metrics.grid) {
            Image(systemName: "arrow.trianglehead.branch")
                .imageScale(.small)
                .foregroundStyle(.text3)
            Text(name)
                .font(Typography.row.weight(.semibold))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .tooltip(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// The header for the history model.
struct HistoryHeaderContainer: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        HistoryHeader(
            content: HistoryHeaderContent(
                style: history.style,
                scope: history.scope,
                count: HistoryHeaderContent.count(
                    loaded: history.commitSHAs.count,
                    total: history.totalCommitCount,
                    isComplete: history.isComplete
                ),
                branchName: repository.gitState.tip.branch?.name,
                search: history.search.map { HistorySearchStatusContent($0, history: history) }
            ),
            setStyle: { style in
                history.setStyle(style)
            },
            setScope: { scope in
                history.setScope(scope)
            },
            search: HistorySearchActions(
                previous: { history.selectPreviousSearchMatch() },
                next: { history.selectNextSearchMatch() },
                searchOlder: {
                    Task {
                        await history.searchOlderCommits()
                    }
                },
                stop: { history.cancelLoading() },
                goToCommit: { sha in
                    Task {
                        await context.state.history.navigator.goToCommit(sha, in: history)
                    }
                }
            )
        )
    }
}
