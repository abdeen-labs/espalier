// The Stashes section, the stash's place, and the stash actions on a real
// repository with stashes on two branches: the current branch's stash first
// with its count, Restore only for it ("Switch to <branch> to restore these
// changes."), Discard… asking first, both going back to Changes from the
// stash's place, and Show/Hide Stashed Changes.

import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A repository on `master` with a stash on `master` (good-file edited,
/// notes.txt added) and one on `feature` (todo.txt added), selected, with a
/// window.
@MainActor
struct StashFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let local: Repository

    static func make() async throws -> StashFixture {
        let local = try await setupTwoCommitRepo()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(local, to: app)
        let fixture = StashFixture(harness: harness, app: app, repository: repository, context: WindowContext(app: app), local: local)

        try harness.write("good-file", "is stashed\n", in: local)
        try harness.write("notes.txt", "notes\n", in: local)
        await fixture.refresh()
        #expect(try await repository.stash.stashAllChanges())
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try harness.write("todo.txt", "todo\n", in: local)
        await fixture.refresh()
        #expect(try await repository.stash.stashAllChanges())
        try await runGit(["checkout", "-q", "master"], local)
        await fixture.refresh()
        #expect(repository.gitState.tip.branch?.name == "master")
        #expect(Set(repository.gitState.stashes.entriesByBranch.keys) == ["master", "feature"])
        return fixture
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

    func entry(_ branch: String) throws -> StashEntry {
        try #require(repository.gitState.stashes.entriesByBranch[branch])
    }

    /// The confirmation the presenter shows, once it does.
    func confirmation() async -> PendingConfirmation {
        await waitUntil { context.presenter.confirmation != nil }
        return context.presenter.confirmation!
    }
}

@Suite("Stashes", .offline, .hangGuard(minutes: 5)) @MainActor
struct StashTests {
    // MARK: Rows

    @Test("the current branch's stash comes first, then the others by name; the filter narrows them")
    func rows() {
        let rows = StashRowContent.rows(
            branches: ["zeta", "feature/b", "main", "Feature/a"],
            currentBranch: "main",
            fileCount: { $0 == "main" ? 4 : nil },
            filter: ""
        )
        #expect(rows.map(\.branch) == ["main", "Feature/a", "feature/b", "zeta"])
        #expect(rows.map(\.badge) == ["4", nil, nil, nil])
        #expect(rows.map(\.isCurrentBranch) == [true, false, false, false])
        #expect(rows[0].accessibilityLabel == "main, 4 files")
        #expect(rows[0].tooltip == "Stashed changes on main")
        #expect(rows[1].tooltip == "Stashed changes on Feature/a. Switch to Feature/a to restore these changes.")

        let filtered = StashRowContent.rows(branches: ["zeta", "feature/b", "main"], currentBranch: "main", fileCount: { _ in 1 }, filter: "FEAT")
        #expect(filtered.map(\.branch) == ["feature/b"])
        #expect(filtered[0].accessibilityLabel == "feature/b, 1 file")
    }

    @Test("the section lists every branch's stash with its count")
    func section() async throws {
        let fixture = try await StashFixture.make()
        fixture.repository.stash.countFiles()
        await fixture.settle()
        let rows = StashRowContent.rows(fixture.repository, filter: "")
        #expect(rows.map(\.branch) == ["master", "feature"])
        #expect(rows.map(\.fileCount) == [2, 1])
    }

    // MARK: The place

    @Test("the column's lines: the branch and count, and what Restore does or why it can't")
    func columnContent() {
        let files = [
            CommittedFileChange(path: "Sources/App/Loader.swift", status: .modified(), commitish: "abc", parentCommitish: "abc^"),
            CommittedFileChange(path: "README.md", status: .new(), commitish: "abc", parentCommitish: "abc^"),
        ]
        var content = StashColumnContent(
            branch: "main",
            files: .loaded(StashColumnContent.files(files, filter: ""), total: 2),
            isCurrentBranch: true,
            canRestore: true,
            canDiscard: true,
            isBusy: false,
            filter: ""
        )
        #expect(content.subtitle == "On main · 2 files")
        #expect(content.explanation == "Restore will move your stashed files to the Changes list.")

        content.isCurrentBranch = false
        #expect(content.explanation == "Switch to main to restore these changes.")
        content.files = .loading
        #expect(content.subtitle == "On main")
        #expect(StashColumnContent.files(files, filter: "loader").map(\.path) == ["Sources/App/Loader.swift"])
        #expect(StashColumnContent.files(files, filter: "LOADER").map(\.path) == ["Sources/App/Loader.swift"])
        #expect(StashColumnContent.files(files, filter: "").map(\.path) == ["Sources/App/Loader.swift", "README.md"])
    }

    @Test("Restore is the current branch's only; Discard is any branch's")
    func enablement() async throws {
        let fixture = try await StashFixture.make()
        let actions = fixture.context.actions
        #expect(actions.canPerform(.restoreStash(branch: "master")))
        #expect(actions.canPerform(.restoreStash(branch: nil)))
        #expect(!actions.canPerform(.restoreStash(branch: "feature")))
        #expect(actions.canPerform(.discardStash(branch: "master")))
        #expect(actions.canPerform(.discardStash(branch: "feature")))
        #expect(!actions.canPerform(.discardStash(branch: "nothing-here")))
        #expect(StashActions.restoreUnavailableReason(branch: "feature") == "Switch to feature to restore these changes.")

        // The row menu's Restore says why it's unavailable under its title.
        let other = StashContextMenu.content(branch: "feature", context: fixture.context).items
        #expect(other.map(\.isEnabled) == [false, true])
        #expect(other.first?.subtitle == "Switch to feature to restore these changes.")
        let current = StashContextMenu.content(branch: "master", context: fixture.context).items
        #expect(current.map(\.isEnabled) == [true, true])
        #expect(current.first?.subtitle == nil)
    }

    @Test("Restore on the stash's place brings the files back and goes to Changes")
    func restore() async throws {
        let fixture = try await StashFixture.make()
        fixture.context.select(.stash(branch: "master"))
        fixture.repository.stash.show(try fixture.entry("master"))
        await fixture.settle()

        await fixture.context.actions.performAndWait(.restoreStash(branch: "master"))
        await fixture.settle()
        #expect(fixture.context.state.place == .changes)
        #expect(fixture.repository.gitState.stashes.entriesByBranch["master"] == nil)
        #expect(Set(fixture.repository.changes.workingDirectory.files.map(\.path)) == ["good-file", "notes.txt"])
        #expect(fixture.context.presenter.error == nil)
        // The other branch's stash stays.
        #expect(fixture.repository.gitState.stashes.entriesByBranch["feature"] != nil)
    }

    @Test("Restore with changes in the way shows the overwritten files with Close only, and keeps the stash")
    func restoreBlocked() async throws {
        let fixture = try await StashFixture.make()
        try fixture.harness.write("good-file", "in the way\n", in: fixture.local)
        await fixture.refresh()
        fixture.context.select(.stash(branch: "master"))

        await fixture.context.actions.performAndWait(.restoreStash(branch: "master"))
        await fixture.settle()
        let error = try #require(fixture.context.presenter.error?.error)
        guard case .alert(let alert, let recoveries) = error.presentation else {
            Issue.record("Expected an alert, got \(error.presentation)")
            return
        }
        #expect(recoveries.isEmpty)
        #expect(alert.buttons.map(\.title) == ["Close"])
        #expect(alert.message.contains("• good-file"))
        #expect(fixture.context.state.place == .stash(branch: "master"))
        #expect(fixture.repository.gitState.stashes.entriesByBranch["master"] != nil)
    }

    @Test("Discard… asks first, then drops the stash; from its place, Changes follows")
    func discard() async throws {
        let fixture = try await StashFixture.make()
        fixture.context.select(.stash(branch: "feature"))
        let task = Task { await fixture.context.actions.performAndWait(.discardStash(branch: "feature")) }

        let pending = await fixture.confirmation()
        #expect(pending.confirmation.kind == .discardStash)
        let alert = pending.confirmation.alertContent
        #expect(alert.title == "Discard Stash?")
        #expect(alert.buttons.map(\.title) == ["Discard", "Cancel"])
        #expect(alert.suppressionTitle == "Do not show this message again")
        fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
        await task.value
        await fixture.settle()

        #expect(fixture.repository.gitState.stashes.entriesByBranch["feature"] == nil)
        #expect(fixture.context.state.place == .changes)
        #expect(fixture.repository.gitState.stashes.entriesByBranch["master"] != nil)
    }

    @Test("discarding another place's stash leaves the window where it is; cancelling keeps the stash")
    func discardElsewhere() async throws {
        let fixture = try await StashFixture.make()
        fixture.context.select(.history)

        let cancelled = Task { await fixture.context.actions.performAndWait(.discardStash(branch: "feature")) }
        fixture.context.presenter.respond(to: await fixture.confirmation().id, with: .cancelled)
        await cancelled.value
        #expect(fixture.repository.gitState.stashes.entriesByBranch["feature"] != nil)

        fixture.app.preferences.confirmDiscardStash = false
        await fixture.context.actions.performAndWait(.discardStash(branch: "feature"))
        await fixture.settle()
        #expect(fixture.repository.gitState.stashes.entriesByBranch["feature"] == nil)
        #expect(fixture.context.state.place == .history)
    }

    @Test("Show/Hide Stashed Changes goes to the current branch's stash and back")
    func toggle() async throws {
        let fixture = try await StashFixture.make()
        let actions = fixture.context.actions
        fixture.context.select(.changes)
        await actions.performAndWait(.toggleStashedChanges)
        #expect(fixture.context.state.place == .stash(branch: "master"))

        fixture.repository.stash.show(try fixture.entry("master"))
        await fixture.settle()
        #expect(actions.title(for: .toggleStashedChanges) == "Hide Stashed Changes")
        await actions.performAndWait(.toggleStashedChanges)
        #expect(fixture.context.state.place == .changes)
        fixture.repository.stash.hide()
        #expect(actions.title(for: .toggleStashedChanges) == "Show Stashed Changes")
    }

    @Test("Stash All Changes asks before replacing the branch's stash")
    func stashAll() async throws {
        let fixture = try await StashFixture.make()
        try fixture.harness.write("great-file", "changed\n", in: fixture.local)
        await fixture.refresh()
        #expect(fixture.context.actions.title(for: .stashAllChanges) == "Stash All Changes…")

        let task = Task { await fixture.context.actions.performAndWait(.stashAllChanges) }
        let pending = await fixture.confirmation()
        #expect(pending.confirmation.kind == .overwriteStash)
        fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
        await task.value
        await fixture.settle()
        #expect(fixture.repository.changes.workingDirectory.files.isEmpty)
        fixture.repository.stash.show(try fixture.entry("master"))
        await fixture.settle()
        #expect(fixture.repository.stash.files.value?.map(\.path) == ["great-file"])
    }
}
