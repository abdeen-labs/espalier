// The repository popover's worktree rows, and the Add and Rename Worktree
// sheets, one capture per layout.

import AppKit
import EspalierCore
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Worktrees", .captures) @MainActor
struct WorktreeCaptures {
    private let area = "Worktrees"

    @Test("rows: the main worktree highlighted, the window's worktree (semibold), a locked one, a detached one, and a missing one")
    func rows() {
        let rows = [
            WorktreeRowContent(path: "/Users/joe/Developer/espalier", detail: "main", isMain: true, isCurrent: false, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-login", detail: "feature/login", isMain: false, isCurrent: true, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-release", detail: "release/2.0", isMain: false, isCurrent: false, isLocked: true),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-bisect", detail: "a1b2c3d", isDetached: true, isMain: false, isCurrent: false, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-spike", detail: "spike/sync", isMain: false, isCurrent: false, isLocked: false, isMissing: true),
        ]
        let list = VStack(alignment: .leading, spacing: 2) {
            ListGroupLabel("Worktrees")
            ForEach(rows) { row in
                WorktreeRow(content: row)
                    .selectableRow(isSelected: row.path == rows[0].path)
            }
        }
        .padding(Metrics.ListRow.inset)
        .frame(width: Metrics.RepositoryPopover.width)
        capture(list, named: "rows", area: area)
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
        capture(addForm(addContent()), named: "add-newBranch", area: area)
        capture(
            addForm(addContent(pathProblem: "There's already a file or folder at /Users/joe/Developer/espalier-login.")),
            named: "add-pathTaken",
            area: area
        )
    }

    @Test("Add Worktree: a worktree name that's no valid branch name")
    func addInvalidName() {
        let name = "HEAD"
        let directory = "/Users/joe/Developer"
        let content = AddWorktreeContent(
            name: name,
            directory: directory,
            branchName: "",
            branchPlaceholder: sanitizedRefName(name),
            branchMessage: AddWorktreeContent.branchMessage(name: name, branchName: "", resolution: nil, branches: []),
            suggestions: [],
            path: "\(directory)/\(name)",
            pathProblem: nil,
            isCreating: false
        )
        capture(addForm(content), named: "add-invalidName", area: area)
    }

    @Test("Add Worktree: a branch name inside a local branch's")
    func addClash() {
        let name = "espalier-login"
        let directory = "/Users/joe/Developer"
        let branchName = "feature/login/fix"
        let feature = Branch(
            name: "feature/login", upstream: nil, tip: BranchTip(sha: String(repeating: "1", count: 40)),
            type: .local, ref: "refs/heads/feature/login"
        )
        let content = AddWorktreeContent(
            name: name,
            directory: directory,
            branchName: branchName,
            branchPlaceholder: sanitizedRefName(name),
            branchMessage: AddWorktreeContent.branchMessage(
                name: name,
                branchName: branchName,
                resolution: .new(name: branchName),
                branches: [feature]
            ),
            suggestions: [],
            path: "\(directory)/\(name)",
            pathProblem: nil,
            isCreating: false
        )
        capture(addForm(content), named: "add-clash", area: area)
    }

    @Test("Rename Worktree, as it opens")
    func rename() {
        capture(
            RenameWorktreeForm(
                content: RenameWorktreeContent(currentName: "espalier-login", name: "espalier-login", problem: nil, isRenaming: false),
                name: .constant("espalier-login")
            ),
            named: "rename",
            area: area
        )
    }
}
