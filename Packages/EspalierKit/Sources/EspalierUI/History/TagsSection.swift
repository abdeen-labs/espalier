// The sidebar's Tags section: the repository's tags, newest version first,
// collapsed by default; a tag created here waits to be pushed with an
// arrow. Selecting one shows the history focused on its commit.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// A tag's row.
nonisolated struct TagRowContent: Sendable, Equatable, Identifiable {
    var name: String
    /// Created here and not pushed yet.
    var isWaitingToBePushed: Bool

    var id: String {
        name
    }

    /// The tags to list: newest version first, those containing `filter`.
    /// Without a remote nothing waits to be pushed.
    static func rows(tags: [String], tagsToPush: Set<String>, hasRemote: Bool = true, filter: String) -> [TagRowContent] {
        tags.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { TagRowContent(name: $0, isWaitingToBePushed: hasRemote && tagsToPush.contains($0)) }
    }
}

/// One tag.
struct TagRow: View {
    let content: TagRowContent

    var body: some View {
        SidebarRowLabel(content.name, systemImage: "tag") {
            if content.isWaitingToBePushed {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.sidebarText3)
                    .tooltip("This tag hasn't been pushed yet")
                    .accessibilityLabel("Not pushed")
            }
        }
    }
}

/// Tags: collapsed by default, shown when the repository has a tag.
public struct TagsSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let tags = Array((repository.gitState.tags ?? [:]).keys)
        if !tags.isEmpty {
            let rows = TagRowContent.rows(
                tags: tags,
                tagsToPush: Set(repository.branches.tagsToPush),
                hasRemote: !repository.gitState.remotes.all.isEmpty,
                filter: context.state.sidebarFilter
            )
            SidebarSection(id: "tags", isExpandedByDefault: false) {
                ForEach(rows) { row in
                    TagRow(content: row)
                        .sidebarRow(.tag(name: row.name))
                        .tag(SidebarPlace.tag(name: row.name))
                }
            } header: {
                SidebarSectionHeader("Tags")
            }
        }
    }
}

/// A tag row's context menu.
enum TagContextMenu {
    @MenuBuilder
    static func content(name: String, context: WindowContext) -> MenuContent {
        let sha = context.repository?.gitState.tags?[name]
        MenuAction("Create Branch from Tag…") {
            if let sha {
                context.actions.perform(.newBranch(startPoint: sha))
            }
        }
        .disabled(sha.map { !context.actions.canPerform(.newBranch(startPoint: $0)) } ?? true)
        MenuAction("Copy Tag Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
        MenuDivider()
        context.actions.menuAction(.deleteTag(name: name), title: "Delete Tag…")
    }
}
