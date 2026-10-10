// The header over History's list: Simple | Graph, then in Graph mode the
// scope pop-up and the commit count, in Simple mode the branch shown; and
// during a search its status (HistorySearch.swift).

import EspalierCore
import GitKit
import SwiftUI

extension Metrics {
    /// The compact header row a History column starts with.
    enum HistoryHeader {
        static let height: CGFloat = 40
        static let horizontalPadding: CGFloat = 14
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
                .help("Show the current branch simply, or every branch as a graph")
                switch content.style {
                case .graph:
                    scopeMenu
                    Spacer(minLength: 0)
                    if content.search == nil {
                        Text(content.count)
                            .font(Typography.secondaryCount)
                            .foregroundStyle(.text3)
                            .lineLimit(1)
                    }
                case .simple:
                    if let branch = content.branchName {
                        Label(branch, systemImage: "arrow.trianglehead.branch")
                            .labelStyle(HeaderLabelStyle())
                            .font(Typography.meta)
                            .foregroundStyle(.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(branch)
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

    /// The scope pop-up: a small quiet capsule with the scope's name.
    private var scopeMenu: some View {
        Menu {
            Picker("Branches", selection: Binding(get: { content.scope }, set: { setScope($0) })) {
                ForEach(HistoryScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(content.scope.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.text3)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.quiet)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which branches the history shows")
        .accessibilityLabel("Branches Shown")
        .accessibilityValue(content.scope.title)
    }
}

/// A symbol 5 points before its title, the symbol a touch smaller.
private struct HeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
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
