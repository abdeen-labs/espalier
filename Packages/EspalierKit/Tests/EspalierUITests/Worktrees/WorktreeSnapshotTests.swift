// The Worktrees section's rows (in light and dark), and the Add and Rename
// Worktree sheets (in light), one image per layout. The sheets' other
// states differ only in words or a disabled button (WorktreeTests), and the
// delete failure is the raw output sheet Errors' clone draws.

import AppKit
import EspalierCore
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Worktree snapshots", .hangGuard(minutes: 5)) @MainActor
struct WorktreeSnapshotTests {
    private let area = "Worktrees"

    @Test("rows: the current worktree, another on a branch, a locked one, and a detached one")
    func rows() {
        let rows = [
            WorktreeRowContent(path: "/Users/joe/Developer/espalier", detail: "main", isMain: true, isCurrent: false, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-login", detail: "feature/login", isMain: false, isCurrent: true, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-release", detail: "release/2.0", isMain: false, isCurrent: false, isLocked: true),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-bisect", detail: "a1b2c3d", isMain: false, isCurrent: false, isLocked: false),
        ]
        let list = List {
            Section {
                ForEach(rows) { row in
                    WorktreeRow(content: row)
                        .sidebarRow(nil, id: row.path, isHighlighted: row.isCurrent)
                }
            } header: {
                SidebarSectionHeader("Worktrees") {
                    Image(systemName: "plus")
                }
            }
        }
        .sidebarListStyle()
        .frame(width: Metrics.Column.sidebar.ideal, height: 150)
        assertSnapshot(list, named: "rows", area: area)
    }

    private func addForm(_ content: AddWorktreeContent) -> some View {
        AddWorktreeForm(content: content, name: .constant(content.name), directory: .constant(content.directory), branchName: .constant(content.branchName))
    }

    private func addContent(pathProblem: String? = nil) -> AddWorktreeContent {
        let name = "espalier-login"
        let directory = "/Users/joe/Developer"
        return AddWorktreeContent(
            name: name,
            directory: directory,
            branchName: "",
            branchPlaceholder: sanitizedRefName(name),
            branchMessage: nil,
            suggestions: [],
            path: "\(directory)/\(name)",
            pathProblem: pathProblem,
            isCreating: false
        )
    }

    @Test("Add Worktree: a new branch, and something in the way")
    func add() {
        assertSnapshot(addForm(addContent()), named: "add-newBranch", area: area, appearances: [.light])
        assertSnapshot(
            addForm(addContent(pathProblem: "There's already a file or folder at /Users/joe/Developer/espalier-login.")),
            named: "add-pathTaken",
            area: area,
            appearances: [.light]
        )
    }

    @Test("Rename Worktree, as it opens")
    func rename() {
        assertSnapshot(
            RenameWorktreeForm(
                content: RenameWorktreeContent(currentName: "espalier-login", name: "espalier-login", problem: nil, isRenaming: false),
                name: .constant("espalier-login")
            ),
            named: "rename",
            area: area,
            appearances: [.light]
        )
    }
}
