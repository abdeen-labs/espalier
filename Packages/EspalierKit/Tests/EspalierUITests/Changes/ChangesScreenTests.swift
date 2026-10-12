// The Changes place with real repositories: the toolbar's text filters the
// list; Space includes and excludes; the context menus' items, from a
// right-click and ⇧F10; selecting a file through AXSelected; the detail
// for one, several, and no files; the header without changes; conflicted
// files in the list and the operation panel; and the menu actions through
// the presenter.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Changes place", .offline, .hangGuard(minutes: 5)) @MainActor
struct ChangesScreenTests {
    /// The place at the window's size.
    private static let size = CGSize(width: 960, height: 620)

    // MARK: The filter

    @Test("the toolbar's search field is the list's filter text")
    func searchFilters() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            fixture.context.state.searchText = "load"
            // The screen applies the field's text when it shows.
            _ = fixture.render(ChangesScreen(repository: fixture.repository), size: Self.size)
            await waitUntil { changes.filter.text == "load" }
            #expect(changes.visibleFiles.map(\.path) == ["Sources/App/Loader.swift"])
            #expect(FileList.listedFiles(fixture.repository).map(\.path) == ["Sources/App/Loader.swift"])

            // Clearing the filters clears the field and the options.
            changes.filter.newFiles = true
            ChangesController(context: fixture.context, repository: fixture.repository).clearFilters()
            #expect(fixture.context.state.searchText.isEmpty)
            #expect(changes.filter == FileListFilter())

            // Showing the included files keeps only them.
            ChangesController(context: fixture.context, repository: fixture.repository).showIncludedFiles()
            #expect(changes.filter == FileListFilter(includedInCommit: true))
            await fixture.app.idle()
        }
    }

    @Test("without a filter, the list has no message for nothing matching")
    func noResults() {
        #expect(NoMatchingFiles.message(for: FileListFilter()) == nil)
    }

    // MARK: Keyboard and menus

    @Test("Space includes each excluded file and excludes the others")
    func spaceToggles() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let controller = ChangesController(context: fixture.context, repository: fixture.repository)
            let readme = try fixture.file("README.md").id
            let loader = try fixture.file("Sources/App/Loader.swift").id
            fixture.repository.changes.setIncluded([readme], false)
            fixture.repository.changes.select(fileIDs: [readme, loader])
            #expect(controller.selectedIDs == [readme, loader])

            controller.toggleInclusion(of: controller.selectedIDs)
            #expect(try fixture.file("README.md").selection.getSelectionType() == .all)
            #expect(try fixture.file("Sources/App/Loader.swift").selection.getSelectionType() == .none)
            await fixture.app.idle()
        }
    }

    @Test("a changed file's menu has desktop's items, for one file and several")
    func contextMenu() {
        let readme = ModelFixtures.file("README.md")
        let loader = ModelFixtures.file("Sources/App/Loader.swift", status: .new())
        let deleted = ModelFixtures.file("Legacy/Old.swift", status: .deleted())
        let ignore = gitIgnoreMenuItems(for: ["Sources/App/Loader.swift"])

        let one = FileContextMenuContent.items(for: [loader], ignoreItems: ignore, editorTitle: "Open in Xcode", asksBeforeDiscarding: true, isRebaseConflicts: false)
        let oneKinds: [FileMenuItem.Kind] = [
            .command(.discard), .separator,
            .command(.ignore(.files(["Sources/App/Loader.swift"]))),
            .submenu([
                FileMenuItem("/Sources/App", .ignore(.files(["/Sources/App"]))),
                FileMenuItem("/Sources", .ignore(.files(["/Sources"]))),
            ]),
            .command(.ignore(.patterns(["*.swift"]))), .separator,
            .command(.copyPaths), .command(.copyRelativePaths), .separator,
            .command(.showInFinder), .command(.openInEditor), .command(.openWithDefaultProgram),
        ]
        #expect(one.map(\.kind) == oneKinds)

        let several = FileContextMenuContent.items(
            for: [readme, deleted],
            ignoreItems: gitIgnoreMenuItems(for: ["README.md", "Legacy/Old.swift"]),
            editorTitle: "Open in Xcode",
            asksBeforeDiscarding: false,
            isRebaseConflicts: false
        )
        let severalKinds: [FileMenuItem.Kind] = [
            .command(.discard), .separator,
            .command(.ignore(.files(["README.md", "Legacy/Old.swift"]))),
            .command(.ignore(.patterns(["*.md"]))), .command(.ignore(.patterns(["*.swift"]))), .separator,
            .command(.include), .command(.exclude), .separator,
            .command(.copyPaths), .command(.copyRelativePaths), .separator,
            .command(.showInFinder), .command(.openInEditor), .command(.openWithDefaultProgram),
        ]
        #expect(several.map(\.kind) == severalKinds)

        // A deleted file can't be shown or opened.
        let gone = FileContextMenuContent.items(for: [deleted], ignoreItems: [], editorTitle: "Open in Xcode", asksBeforeDiscarding: true, isRebaseConflicts: false)
        #expect(gone.suffix(3).allSatisfy { !$0.isEnabled })

        // During a rebase's conflicts: discard (untracked only), copy, open.
        let rebase = FileContextMenuContent.items(for: [readme], ignoreItems: [], editorTitle: "Open in Xcode", asksBeforeDiscarding: true, isRebaseConflicts: true)
        let rebaseKinds: [FileMenuItem.Kind] = [
            .command(.copyPaths), .command(.copyRelativePaths), .separator,
            .command(.showInFinder), .command(.openInEditor), .command(.openWithDefaultProgram),
        ]
        #expect(rebase.map(\.kind) == rebaseKinds)
        let untracked = FileContextMenuContent.items(
            for: [ModelFixtures.file("notes.txt", status: .untracked())],
            ignoreItems: [],
            editorTitle: nil,
            asksBeforeDiscarding: true,
            isRebaseConflicts: true
        )
        #expect(untracked.first?.kind == FileMenuItem.Kind.command(.discard))
    }

    @Test("the menu acts on the files: include, ignore, copy, discard through the presenter")
    func menuCommands() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let controller = ChangesController(context: fixture.context, repository: fixture.repository)
            let loader = try fixture.file("Sources/App/Loader.swift")
            let readme = try fixture.file("README.md")

            controller.run(.exclude, on: [loader.id, readme.id])
            #expect(try fixture.file("README.md").selection.getSelectionType() == .none)
            controller.run(.include, on: [readme.id])
            #expect(try fixture.file("README.md").selection.getSelectionType() == .all)

            #expect(controller.absolutePaths([readme]) == POSIXPath.join(fixture.local.path, "README.md"))
            #expect(controller.relativePaths([loader, readme]) == "Sources/App/Loader.swift\nREADME.md")

            // Ignoring adds the file to .gitignore; the list follows.
            controller.run(.ignore(.files(["Sources/App/Loader.swift"])), on: [loader.id])
            await waitUntil { fixture.repository.changes.workingDirectory.files.contains { $0.path == ".gitignore" } }
            #expect(!fixture.repository.changes.workingDirectory.files.contains { $0.path == "Sources/App/Loader.swift" })

            // Discarding asks first; Cancel keeps the file.
            controller.run(.discard, on: [readme.id])
            await waitUntil { fixture.context.presenter.confirmation != nil }
            let pending = try #require(fixture.context.presenter.confirmation)
            #expect(pending.confirmation.kind == .discardChanges)
            fixture.context.presenter.respond(to: pending.id, with: .cancelled)
            await fixture.settle()
            #expect((try? fixture.file("README.md")) != nil)
            await fixture.app.idle()
        }
    }

    // MARK: The detail

    @Test("the right side: one file's diff, several files, none, or Suggestions")
    func detail() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let readme = try fixture.file("README.md")
            changes.select(fileIDs: [readme.id])
            #expect(ChangesDetailKind.make(fixture.repository) == .diff(readme))
            changes.select(fileIDs: [readme.id, try fixture.file("LICENSE").id])
            #expect(ChangesDetailKind.make(fixture.repository) == .multiple(count: 2))
            changes.select(fileIDs: [])
            #expect(ChangesDetailKind.make(fixture.repository) == .none)
            await fixture.app.idle()
        }
    }

    @Test("leaving a line out in the diff's gutter makes the file's checkbox mixed; including the file takes it in whole again")
    func partialGutterStaging() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let readme = try fixture.file("README.md")
            changes.select(fileIDs: [readme.id])
            await fixture.settle()

            // Gutter staging (the diff through the changes model): the last
            // added line left out, so the row's checkbox is mixed.
            #expect(changes.canSelectLines)
            let selection = try #require(changes.diffSelection)
            changes.setLineSelection(selection.withLineSelection(4, selected: false), forFile: readme.id)
            await fixture.settle()
            #expect(try fixture.file("README.md").selection.getSelectionType() == .partial)
            #expect(ChangesHeaderContent.make(fixture.repository, numberFormat: defaultNumberFormat).includeAll == nil)
            changes.setIncluded([readme.id], true)
            await fixture.settle()
            #expect(try fixture.file("README.md").selection.getSelectionType() == .all)
            await fixture.app.idle()
        }
    }

    // MARK: Actions

    @Test("Commit Changes commits through the presenter, asking about hidden files first")
    func commitAction() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            let actions = fixture.context.actions

            // No summary: the menu item waits.
            #expect(!actions.canPerform(.commitChanges))
            repository.commit.draft.summary = "Update everything"
            #expect(actions.canPerform(.commitChanges))
            // Only from Changes, where the composer is.
            fixture.context.state.select(.history, in: repository.id)
            #expect(!actions.canPerform(.commitChanges))
            fixture.context.state.select(.changes, in: repository.id)

            // A filter hides included files: the presenter asks.
            repository.changes.filter.text = "load"
            let task = Task { await actions.performAndWait(.commitChanges) }
            await waitUntil { fixture.context.presenter.confirmation != nil }
            let pending = try #require(fixture.context.presenter.confirmation)
            #expect(pending.confirmation.kind == .commitFilteredChanges)
            fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
            await task.value
            await fixture.settle()
            #expect(repository.changes.workingDirectory.files.isEmpty)
            #expect(repository.commit.draft.summary.isEmpty)
            #expect(repository.commit.mostRecentLocalCommit?.summary == "Update everything")

            // Undo Commit… takes it back (no changes left, so it doesn't ask).
            #expect(actions.canPerform(.undoCommit))
            await actions.performAndWait(.undoCommit)
            await fixture.settle()
            #expect(repository.changes.workingDirectory.files.count == 3)
            #expect(repository.commit.draft.summary == "Update everything")
            #expect(!actions.canPerform(.undoCommit))
            await fixture.app.idle()
        }
    }

    @Test("Amend Last Commit toggles amending; Go to Commit Message shows Changes and focuses the summary")
    func amendAndFocus() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let actions = fixture.context.actions
            #expect(actions.canPerform(.toggleAmendLastCommit))
            // The pushed commit asks first.
            let task = Task { await actions.performAndWait(.toggleAmendLastCommit) }
            await waitUntil { fixture.context.presenter.confirmation != nil }
            let pending = try #require(fixture.context.presenter.confirmation)
            #expect(pending.confirmation.kind == .rewritePublishedCommits)
            fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
            await task.value
            #expect(actions.isChecked(.toggleAmendLastCommit))
            await actions.performAndWait(.toggleAmendLastCommit)
            #expect(!actions.isChecked(.toggleAmendLastCommit))

            fixture.context.state.select(.history, in: fixture.repository.id)
            let request = fixture.context.state.commitMessageFocusRequest
            await actions.performAndWait(.goToCommitMessage)
            #expect(fixture.context.state.place == .changes)
            #expect(fixture.context.state.commitMessageFocusRequest == request + 1)
            await fixture.app.idle()
        }
    }

    // MARK: Edit ▸ Delete (⌘⌫)

    /// The place in a window that stays up, so focus can move in it: the key
    /// window, or one that isn't key (as when a popover's is).
    private func hostPlace(_ fixture: ChangesWindowFixture, isKey: Bool = true) -> NSWindow {
        let rect = CGRect(origin: .zero, size: Self.size)
        let window = isKey
            ? SnapshotWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Snapshot.deterministic(
            ChangesScreen(repository: fixture.repository).windowEnvironment(fixture.context)
        ))
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// The first view of `type` in `view`'s hierarchy.
    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else {
            return nil
        }
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = find(type, in: subview) {
                return match
            }
        }
        return nil
    }

    @Test("⌘⌫ discards the selected file while the Changes list has focus")
    func deleteFromList() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            // Without the confirmation, Delete discards at once.
            fixture.app.preferences.confirmDiscardChanges = false
            let changes = fixture.repository.changes
            let actions = fixture.context.actions
            changes.select(fileIDs: [try fixture.file("README.md").id])
            let window = hostPlace(fixture)
            defer { window.contentView = nil }
            #expect(!actions.canPerform(.deleteSelection))

            let list = try #require(find(ChangesTableView.self, in: window.contentView))
            #expect(window.makeFirstResponder(list))
            #expect(actions.canPerform(.deleteSelection))
            #expect(actions.canPerform(.copyPath))
            await actions.performAndWait(.deleteSelection)
            await waitUntil { !changes.workingDirectory.files.contains { $0.path == "README.md" } }
            #expect(changes.workingDirectory.files.map(\.path).sorted() == ["LICENSE", "Sources/App/Loader.swift"])
            #expect(fixture.context.presenter.confirmation == nil)
            await fixture.settle()
        }
    }

    @Test("⌘⌫ is off and discards nothing while the commit message, or nothing, has focus")
    func deleteElsewhere() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            // Without the confirmation, a Delete that got through would
            // discard at once.
            fixture.app.preferences.confirmDiscardChanges = false
            let changes = fixture.repository.changes
            let actions = fixture.context.actions
            changes.select(fileIDs: [try fixture.file("README.md").id])
            let window = hostPlace(fixture)
            defer { window.contentView = nil }
            let list = try #require(find(ChangesTableView.self, in: window.contentView))
            #expect(window.makeFirstResponder(list))
            #expect(actions.canPerform(.deleteSelection))

            // The summary takes focus from the list (as a click in it does).
            let summary = try #require(find(SummaryNSTextField.self, in: window.contentView))
            #expect(window.makeFirstResponder(summary))
            #expect(summary.currentEditor() != nil)
            #expect(fixture.context.state.focusedSelection == nil)
            #expect(!actions.canPerform(.deleteSelection))
            await actions.performAndWait(.deleteSelection)

            // The description, then nothing.
            let description = try #require(find(ComposerTextView.self, in: window.contentView))
            #expect(window.makeFirstResponder(description))
            #expect(!actions.canPerform(.deleteSelection))
            await actions.performAndWait(.deleteSelection)
            #expect(window.makeFirstResponder(nil))
            #expect(!actions.canPerform(.deleteSelection))
            await actions.performAndWait(.deleteSelection)

            await fixture.settle()
            #expect(fixture.context.presenter.confirmation == nil)
            #expect(changes.workingDirectory.files.map(\.path).sorted() == ["LICENSE", "README.md", "Sources/App/Loader.swift"])
            #expect(try String(contentsOfFile: POSIXPath.join(local.path, "README.md"), encoding: .utf8) == "# Readme\n\nChanged.\n")
        }
    }

    @Test("⌘⌫ is off and discards nothing while another window is key, though the list keeps its window's focus")
    func deleteFromAnotherWindow() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            fixture.app.preferences.confirmDiscardChanges = false
            let changes = fixture.repository.changes
            let actions = fixture.context.actions
            changes.select(fileIDs: [try fixture.file("README.md").id])
            // A popover's window is key (its search field gets the keys);
            // the main window keeps the list as its first responder.
            let window = hostPlace(fixture, isKey: false)
            defer { window.contentView = nil }
            #expect(!window.isKeyWindow)
            let list = try #require(find(ChangesTableView.self, in: window.contentView))
            #expect(window.makeFirstResponder(list))
            #expect(fixture.context.state.focusedSelection != nil)
            #expect(!actions.canPerform(.deleteSelection))
            #expect(!actions.canPerform(.copyPath))
            await actions.performAndWait(.deleteSelection)
            await fixture.settle()
            #expect(fixture.context.presenter.confirmation == nil)
            #expect(changes.workingDirectory.files.map(\.path).sorted() == ["LICENSE", "README.md", "Sources/App/Loader.swift"])
            #expect(try String(contentsOfFile: POSIXPath.join(local.path, "README.md"), encoding: .utf8) == "# Readme\n\nChanged.\n")
        }
    }

    @Test("⇧F10 opens the menu at the row selected last, and nothing without a selection; a right-click on another file opens the menu at its row and rings it")
    func keyboardContextMenu() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            changes.select(fileIDs: [])
            let window = hostPlace(fixture)
            defer { window.contentView = nil }
            let list = try #require(find(ChangesTableView.self, in: window.contentView))
            #expect(window.makeFirstResponder(list))
            let recorder = MenuRecorder()
            let key = try f10KeyDown(in: window)
            #expect(KeyboardContextMenu.handle(key, in: window, presenter: recorder.menuPresenter))
            #expect(recorder.popups.isEmpty)

            // Two files, README.md selected last: the menu, at its row.
            let files = FileList.listedFiles(fixture.repository)
            let license = try #require(files.firstIndex { $0.path == "LICENSE" })
            let readme = try #require(files.firstIndex { $0.path == "README.md" })
            list.selectRowIndexes([license], byExtendingSelection: false)
            list.selectRowIndexes([readme], byExtendingSelection: true)
            #expect(KeyboardContextMenu.handle(key, in: window, presenter: recorder.menuPresenter))
            let popup = try #require(recorder.popups.first)
            #expect(popup.view === list)
            #expect(list.row(at: popup.location) == readme)
            #expect(list.contextMenuTarget.row == readme)
            popup.close()

            // A right-click on the file left out of the selection: the menu,
            // at the pointer, its row ringed; the selection stays.
            let loader = try #require(files.firstIndex { $0.path == "Sources/App/Loader.swift" })
            #expect(ContextMenuRegions.openMenu(for: try rightClick(row: loader, in: list), presenter: recorder.menuPresenter))
            let single = try #require(recorder.popups.last)
            #expect(list.row(at: single.location) == loader)
            #expect(list.contextMenuTarget.row == loader)
            #expect((list.rowView(atRow: loader, makeIfNecessary: false) as? FileTableRowView)?.isContextMenuTarget == true)
            #expect(list.selectedRowIndexes == [license, readme])
            single.close()
            #expect(list.contextMenuTarget.row == nil)
            await fixture.settle()
        }
    }

    @Test("setting AXSelected on a file's cell selects its file alone, as a click does, and the diff follows")
    func accessibilitySelect() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let readme = try fixture.file("README.md").id
            changes.select(fileIDs: [readme])
            await fixture.settle()
            let window = hostPlace(fixture)
            defer { window.contentView = nil }
            let list = try #require(find(ChangesTableView.self, in: window.contentView))
            let row = try #require(FileList.listedFiles(fixture.repository).firstIndex { $0.path == "LICENSE" })
            let cell = try #require(list.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowView)
            #expect(cell.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.setAccessibilitySelected(_:))))
            #expect(!cell.isAccessibilitySelected())

            cell.setAccessibilitySelected(true)
            let license = try fixture.file("LICENSE").id
            #expect(changes.selection == .workingDirectory(fileIDs: [license]))
            #expect(cell.isAccessibilitySelected())
            await fixture.settle()
            #expect(changes.diffFileID == license)
        }
    }

    // MARK: Conflicts, and no changes

    @Test("a merge's conflicts: the conflicted file in the list with its state, the operation panel, and the merge's commit form")
    func conflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesWindowFixture.make(try await setupConflictedRepo())
            await fixture.settle()
            // The conflicted file is a row of the one list, with its state.
            let listed = FileList.listedFiles(fixture.repository)
            #expect(listed.map(\.path) == ["foo"])
            #expect(FileList.conflictRows(fixture.repository)[ExactString("foo")]?.state == .markers(conflicts: 1))
            #expect(OperationCapsuleContent.make(fixture.repository) != nil)
            #expect(ChangesFooterLayout.make(fixture.repository, showsOperationPanel: true).bottom == .merge)
            await fixture.app.idle()
        }
    }

    @Test("without changes, the list is empty, the header counts nothing included, and its checkbox can't change")
    func noChangesHeader() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            try await fixture.repository.stash.stashAllChanges()
            await fixture.settle()
            let header = ChangesHeaderContent.make(fixture.repository, numberFormat: defaultNumberFormat)
            #expect(header.included.isEmpty)
            #expect(!header.isIncludeAllEnabled)
            #expect(FileList.listedFiles(fixture.repository).isEmpty)
            #expect(ChangesDetailKind.make(fixture.repository) == .suggestions)
            await fixture.app.idle()
        }
    }
}
