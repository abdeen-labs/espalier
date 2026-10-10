// The Worktrees section, the Add and Rename sheets' rules, and the worktree
// actions, on real repositories: rows with their branch or SHA, the current
// one and locked ones; the sheets' hints; a name with "/" refused;
// switching; Delete… asking, and when git refuses, "Couldn't delete the
// worktree <name>." with Cancel and Delete Anyway.

import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A repository on `master` with a branch `feature`, selected, with a
/// window; `linked()` adds a worktree on `feature` with git.
@MainActor
struct WorktreeUIFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let main: Repository
    /// Where the tests' worktrees go.
    let directory: String

    static func make() async throws -> WorktreeUIFixture {
        let main = try await setupTwoCommitRepo()
        try await runGit(["branch", "feature", "HEAD~1"], main)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(main, to: app)
        let directory = try createTempDirectory(prefix: "espalier-worktrees-")
        return WorktreeUIFixture(harness: harness, app: app, repository: repository, context: WindowContext(app: app), main: main, directory: directory)
    }

    /// Adds a worktree with git (`git worktree add <arguments…>` with its
    /// path first), refreshes, and returns it.
    @discardableResult
    func linked(_ name: String = "feature-tree", _ arguments: [String] = ["feature"]) async throws -> WorktreeEntry {
        let path = POSIXPath.join(directory, name)
        try await runGit(["worktree", "add", path] + arguments, main)
        await refresh()
        return try #require(repository.worktrees.entries.first { $0.path == path })
    }

    func refresh() async {
        await repository.refresh(.full, reason: .user)
        await settle()
    }

    func settle() async {
        await app.idle()
        await context.actions.idle()
        await app.idle()
    }

    func confirmation() async -> PendingConfirmation {
        await waitUntil { context.presenter.confirmation != nil }
        return context.presenter.confirmation!
    }
}

@Suite("Worktrees", .offline, .hangGuard(minutes: 5)) @MainActor
struct WorktreeTests {
    // MARK: Rows

    @Test("rows: the main worktree first, each with its branch or short SHA; current, locked, and the filter")
    func rows() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let feature = try await fixture.linked()
        let detached = try await fixture.linked("detached-tree", ["--detach", "HEAD"])
        try await runGit(["worktree", "lock", detached.path], fixture.main)
        await fixture.refresh()

        let worktrees = fixture.repository.worktrees
        let rows = WorktreeRowContent.rows(worktrees.entries, currentPath: worktrees.current?.path, filter: "")
        #expect(rows.count == 3)
        #expect(rows[0].isMain && rows[0].isCurrent)
        #expect(rows[0].detail == "master")
        #expect(rows[0].symbol == "checkmark.circle.fill")
        #expect(!rows[0].canRenameOrDelete)
        let featureRow = try #require(rows.first { $0.path == feature.path })
        #expect(featureRow.name == "feature-tree")
        #expect(featureRow.detail == "feature")
        #expect(featureRow.symbol == "rectangle.stack")
        #expect(featureRow.canRenameOrDelete)
        let detachedRow = try #require(rows.first { $0.path == detached.path })
        #expect(detachedRow.isLocked)
        #expect(!detachedRow.canRenameOrDelete)
        #expect(detachedRow.detail.count == 7)
        #expect(detachedRow.tooltip == "\(detached.path)\nThis worktree is locked.")
        #expect(detachedRow.accessibilityLabel == "detached-tree, \(detachedRow.detail), locked")

        let filtered = WorktreeRowContent.rows(worktrees.entries, currentPath: worktrees.current?.path, filter: "FEATURE")
        #expect(filtered.map(\.path) == [feature.path])
    }

    @Test("the list shows with two worktrees, with the setting, or after Show Worktrees")
    func visibility() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let state = fixture.context.state.featureState(WorktreesWindowState.self) { WorktreesWindowState() }
        #expect(!fixture.repository.worktrees.isListVisible)
        #expect(state.revealedRepository == nil)

        fixture.context.state.columnVisibility = .detailOnly
        await fixture.context.actions.performAndWait(.showWorktrees)
        #expect(state.revealedRepository == fixture.repository.id)
        #expect(fixture.context.state.columnVisibility == .all)

        fixture.app.preferences.alwaysShowWorktreeList = true
        #expect(fixture.repository.worktrees.isListVisible)
        fixture.app.preferences.alwaysShowWorktreeList = false
        try await fixture.linked()
        #expect(fixture.repository.worktrees.isListVisible)
    }

    // MARK: Add Worktree

    @Test("Add Worktree: the folder, the branch hints, and what's in the way")
    func addContent() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let repository = fixture.repository
        var content = AddWorktreeContent.make(name: "", directory: fixture.directory, branchName: "", repository: repository, isCreating: false)
        #expect(content.path == nil)
        #expect(content.footer == nil)
        #expect(!content.canCreate)

        content = AddWorktreeContent.make(name: "espalier-login", directory: fixture.directory, branchName: "", repository: repository, isCreating: false)
        let path = POSIXPath.join(fixture.directory, "espalier-login")
        #expect(content.path == path)
        #expect(content.footer == "Worktree will be created at \(path).")
        #expect(content.branchPlaceholder == "espalier-login")
        #expect(content.branchMessage == nil)
        #expect(content.canCreate)

        content = AddWorktreeContent.make(name: "espalier-login", directory: fixture.directory, branchName: "feature", repository: repository, isCreating: false)
        #expect(content.branchMessage == .init(text: "Will check out existing branch feature.", isError: false))
        #expect(content.canCreate)

        content = AddWorktreeContent.make(name: "espalier-login", directory: fixture.directory, branchName: "my login", repository: repository, isCreating: false)
        #expect(content.branchMessage == .init(text: "Will be created as my-login.", isError: false))

        content = AddWorktreeContent.make(name: "espalier-login", directory: fixture.directory, branchName: "..", repository: repository, isCreating: false)
        #expect(content.branchMessage == .init(text: ".. is not a valid name.", isError: true))
        #expect(!content.canCreate)

        content = AddWorktreeContent.make(name: "x", directory: fixture.directory, branchName: "", repository: repository, isCreating: false) { _ in .folder }
        #expect(content.pathProblem == "There's already a file or folder at \(POSIXPath.join(fixture.directory, "x")).")
        #expect(!content.canCreate)
        content = AddWorktreeContent.make(name: "x", directory: fixture.directory, branchName: "", repository: repository, isCreating: false) { _ in .emptyFolder }
        #expect(content.pathProblem == nil)
        content = AddWorktreeContent.make(name: "x", directory: fixture.directory, branchName: "", repository: repository, isCreating: true)
        #expect(!content.canCreate)
    }

    @Test("Add Worktree: what's on disk, and the branch completions")
    func addHelpers() throws {
        let directory = try createTempDirectory()
        #expect(AddWorktreeContent.item(at: POSIXPath.join(directory, "missing")) == .none)
        #expect(AddWorktreeContent.item(at: directory) == .emptyFolder)
        try Data("x".utf8).write(to: URL(filePath: POSIXPath.join(directory, "file")))
        #expect(AddWorktreeContent.item(at: directory) == .folder)
        #expect(AddWorktreeContent.item(at: POSIXPath.join(directory, "file")) == .file)

        let branches = [
            Branch(name: "origin/feature", upstream: nil, tip: BranchTip(sha: "a"), type: .remote, ref: "refs/remotes/origin/feature"),
            Branch(name: "main", upstream: nil, tip: BranchTip(sha: "b"), type: .local, ref: "refs/heads/main"),
            Branch(name: "feature/login", upstream: nil, tip: BranchTip(sha: "c"), type: .local, ref: "refs/heads/feature/login"),
        ]
        #expect(AddWorktreeContent.suggestions(for: "", in: branches) == ["main", "feature/login", "origin/feature"])
        #expect(AddWorktreeContent.suggestions(for: "FEAT", in: branches) == ["feature/login", "origin/feature"])
    }

    @Test("Check Out in New Worktree… names the worktree after the repository and the branch, or the pull request")
    func addInitialValues() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let repository = fixture.repository
        let name = repository.record.name
        var initial = AddWorktreeSheet.initialValues(branch: nil, pullRequest: nil, repository: repository)
        #expect(initial.name.isEmpty)
        #expect(initial.branchName.isEmpty)
        #expect(initial.directory == fixture.app.preferences.lastCloneLocation)

        initial = AddWorktreeSheet.initialValues(branch: "feature", pullRequest: nil, repository: repository)
        #expect(initial.name == "\(name)-feature")
        #expect(initial.branchName == "feature")
        initial = AddWorktreeSheet.initialValues(branch: "origin/fix/crash", pullRequest: 142, repository: repository)
        #expect(initial.name == "\(name)-142")
        #expect(initial.branchName == "origin/fix/crash")
        initial = AddWorktreeSheet.initialValues(branch: "fix/crash", pullRequest: nil, repository: repository)
        #expect(initial.name == "\(name)-fix-crash")
    }

    @Test("adding a worktree switches the window to it")
    func add() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let path = POSIXPath.join(fixture.directory, "login")
        let added = await fixture.context.presenter.perform { _ throws(OperationError) in
            try await fixture.repository.worktrees.add(AddWorktreeRequest(path: path, branchName: "login"))
        }
        await fixture.settle()
        #expect(added != nil)
        #expect(AddWorktreeSheet.isSamePath(fixture.repository.record.path, path))
        #expect(fixture.repository.gitState.tip.branch?.name == "login")
    }

    // MARK: Rename

    @Test("Rename: a folder's name only, a new one, and not one already taken")
    func renameContent() throws {
        let parent = try createTempDirectory()
        let path = POSIXPath.join(parent, "feature-tree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: POSIXPath.join(parent, "taken"), withIntermediateDirectories: true)

        var content = RenameWorktreeContent.make(path: path, name: "feature-tree", isRenaming: false)
        #expect(content.buttonTitle == "Rename feature-tree")
        #expect(content.problem == nil)
        #expect(!content.canRename)

        content = RenameWorktreeContent.make(path: path, name: "login-tree", isRenaming: false)
        #expect(content.canRename)
        content = RenameWorktreeContent.make(path: path, name: "elsewhere/login-tree", isRenaming: false)
        #expect(content.problem == "Worktree names can't contain “/”.")
        #expect(!content.canRename)
        content = RenameWorktreeContent.make(path: path, name: "taken", isRenaming: false)
        #expect(content.problem == "The name “taken” is already taken. Choose a different name.")
        #expect(!content.canRename)
        content = RenameWorktreeContent.make(path: path, name: "   ", isRenaming: false)
        #expect(!content.canRename)
        content = RenameWorktreeContent.make(path: path, name: "login-tree", isRenaming: true)
        #expect(!content.canRename)
    }

    @Test("Rename… and Delete… aren't offered for the main worktree or a locked one")
    func menuRules() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let feature = try await fixture.linked()
        let locked = try await fixture.linked("locked-tree", ["--detach", "HEAD"])
        try await runGit(["worktree", "lock", locked.path], fixture.main)
        await fixture.refresh()
        let actions = fixture.context.actions
        let mainPath = try #require(fixture.repository.worktrees.main?.path)
        for path in [mainPath, locked.path] {
            #expect(!actions.canPerform(.renameWorktree(path: path)))
            #expect(!actions.canPerform(.deleteWorktree(path: path)))
        }
        #expect(actions.canPerform(.renameWorktree(path: feature.path)))
        #expect(actions.canPerform(.deleteWorktree(path: feature.path)))
        #expect(!actions.canPerform(.deleteWorktree(path: "/nowhere")))
        #expect(actions.canPerform(.switchToWorktree(path: feature.path)))
        #expect(actions.canPerform(.newWorktree(branch: nil)))
    }

    // MARK: Switching and deleting

    @Test("clicking a worktree switches the window to it")
    func switching() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let feature = try await fixture.linked()
        await fixture.context.actions.performAndWait(.switchToWorktree(path: feature.path))
        await fixture.settle()
        #expect(AddWorktreeSheet.isSamePath(fixture.repository.record.path, feature.path))
        #expect(fixture.repository.gitState.tip.branch?.name == "feature")
        #expect(fixture.context.presenter.error == nil)
    }

    @Test("Delete… asks first, with its suppression toggle, then deletes the worktree")
    func delete() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let feature = try await fixture.linked()
        let task = Task { await fixture.context.actions.performAndWait(.deleteWorktree(path: feature.path)) }
        let pending = await fixture.confirmation()
        guard case .alert(let alert) = pending.confirmation.presentation else {
            Issue.record("Expected an alert")
            return
        }
        #expect(alert.title == "Delete Worktree")
        #expect(alert.message == "Are you sure you want to delete the worktree feature-tree?")
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(alert.suppressionTitle == "Do not show this message again")
        fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
        await task.value
        await fixture.settle()
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(fixture.repository.worktrees.entries.count == 1)
        #expect(!fixture.app.preferences.confirmWorktreeRemoval)
    }

    @Test("when git refuses, \"Couldn't delete the worktree <name>.\" offers Delete Anyway, with Cancel")
    func deleteFails() async throws {
        let fixture = try await WorktreeUIFixture.make()
        fixture.app.preferences.confirmWorktreeRemoval = false
        let feature = try await fixture.linked()
        try fixture.harness.write("untracked.txt", "in the way\n", in: Repository(path: feature.path))

        await fixture.context.actions.performAndWait(.deleteWorktree(path: feature.path))
        await fixture.settle()
        let presented = try #require(fixture.context.presenter.error)
        let error = presented.error
        #expect(error.title == "Delete Worktree Failed")
        switch error.presentation {
        case .rawOutput(let content, let recoveries):
            #expect(content.title == "Delete Worktree Failed")
            #expect(content.message == "Couldn't delete the worktree feature-tree.")
            #expect(content.output.contains("contains modified or untracked files"))
            #expect(content.note == "Delete the worktree feature-tree anyway?")
            #expect(content.recoveryTitles == ["Delete Anyway"])
            #expect(content.dismissTitle == "Cancel")
            #expect(recoveries.count == 1)
        case .alert(let alert, let recoveries):
            #expect(alert.message.hasPrefix("Couldn't delete the worktree feature-tree.\n\n"))
            #expect(alert.buttons.map(\.title) == ["Delete Anyway", "Cancel"])
            #expect(recoveries.count == 1)
        default:
            Issue.record("Unexpected presentation \(error.presentation)")
        }
        #expect(FileManager.default.fileExists(atPath: feature.path))

        // Delete Anyway.
        await fixture.context.presenter.recover(presented.id, with: error.recoveries[0])
        await fixture.settle()
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(fixture.context.presenter.error == nil)
    }

    @Test("the delete failure's presentation, from its error alone")
    func deleteFailurePresentation() {
        let worktree = WorktreeEntry(path: "/Users/joe/Developer/espalier-login", head: "a1b2c3d", branch: "refs/heads/login", isDetached: false, type: .linked, isLocked: false, isPrunable: false)
        let retry = RemoveWorktreeRetry(repositoryID: UIFixtures.repositoryID, worktree: worktree)
        let output = "fatal: working trees containing submodules cannot be moved or removed"
        let error = OperationError(
            .git(UIFixtures.gitFailure(output, raw: true)),
            operation: .removeWorktree,
            repositoryID: UIFixtures.repositoryID,
            retry: retry,
            recoveries: [.retry(retry)]
        )
        guard case .rawOutput(let content, _) = error.presentation else {
            Issue.record("Expected git's output")
            return
        }
        #expect(content == RawOutputContent(
            title: "Delete Worktree Failed",
            message: "Couldn't delete the worktree espalier-login.",
            output: output,
            note: "Delete the worktree espalier-login anyway?",
            recoveryTitles: ["Delete Anyway"],
            dismissTitle: "Cancel"
        ))
    }
}
