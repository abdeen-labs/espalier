// History's views without a repository: a search for a SHA, a place's
// notice in All Branches, a commit header's links, a file at the root, a
// commit's files as a Mac list, the tag sheet's previous tags and when it
// can create, Go to Commit's IDs, and tag rows.

import AppKit
@testable import EspalierCore
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History views") @MainActor
struct HistoryViewModelTests {
    // MARK: Search

    @Test("a search for a SHA offers its commit by its short ID")
    func search() {
        var sha = HistorySearch(query: "a1b2c3d4")
        sha.isSearching = false
        let content = HistorySearchStatusContent(search: sha, loaded: 2_400, isComplete: false, isLoadingMore: false)
        #expect(content.shortCommitID == "a1b2c3d")
    }

    // MARK: A place's notice

    @Test("a place's notice offers nothing more to show when the graph shows All Branches")
    func placeNotice() {
        // All Branches reaches every branch and tag: nothing more to show.
        #expect(HistoryPlaceNotice(place: .tag(name: "v1.0"), name: "v1.0", kind: .outsideScope(.allBranches)).actionTitle == nil)
    }

    // MARK: The commit detail

    @Test("a commit's header links issue references and mentions to its GitHub repository, and nothing without one")
    func commitHeaderLinks() {
        var rich = CommitHeaderContent(
            sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            summary: "Fix #12 :tada: thanks @octocat",
            description: "",
            authorName: "Joe Bloggs",
            authorEmail: "joe@example.com",
            avatarEndpoint: nil,
            date: UIFixtures.minutesAgo(120),
            tags: []
        )
        rich.gitHubRepository = gitHubRepoFixture(owner: "octo", name: "app")
        var plain = rich
        plain.gitHubRepository = nil
        plain.underlinesLinks = false
        #expect(rich.richSummary.runs.compactMap(\.link).map(\.absoluteString) == ["https://github.com/octo/app/issues/12", "https://github.com/octocat"])
        #expect(plain.richSummary.runs.compactMap(\.link).isEmpty)
    }

    @Test("a file at the repository's root has no folder")
    func rootFile() {
        #expect(CommittedFileRowContent(id: "1", path: "Legacy.swift", status: .deleted).directory == "")
    }

    @Test("a commit's files work as a Mac list: ⇧F10 opens the selected file's menu at it, a right-click another file's, ringing it; typing selects by name, Return opens the file")
    func filesKeyboard() throws {
        let files = ["a.swift", "b.swift", "c.swift"].enumerated().map { index, path in
            HistoryFileContent(file: CommittedFileRowContent(id: "\(index)", path: path, status: .modified))
        }
        let recorder = FileListRecorder()
        let actions = HistoryFilesActions(
            select: { recorder.selected.append($0) },
            open: { recorder.opened.append($0) },
            menu: { id in
                MenuContent {
                    MenuAction("Open") { recorder.menuChosen.append(id) }
                }
            }
        )
        let list = HistoryFileList(files: files, selection: "1", actions: actions)
        let (window, host) = hostInWindow(list.frame(width: 300, height: 200), size: CGSize(width: 300, height: 200))
        defer { window.contentView = nil }
        let table = try #require(firstView(HistoryFileTableView.self, in: host))
        let controller = try #require(table.controller)
        #expect(table.selectedRow == 1)

        window.makeFirstResponder(table)
        let menus = MenuRecorder()
        #expect(KeyboardContextMenu.handle(try f10KeyDown(in: window), in: window, presenter: menus.menuPresenter))
        #expect(table.contextMenuTarget.row == 1)
        menus.popups.first?.choose("Open")
        menus.popups.first?.close()
        #expect(ContextMenuRegions.openMenu(for: try rightClick(row: 2, in: table), presenter: menus.menuPresenter))
        #expect(table.contextMenuTarget.row == 2)
        #expect(table.selectedRow == 1)
        menus.popups.last?.choose("Open")
        #expect(recorder.menuChosen == ["1", "2"])

        #expect(controller.tableView(table, typeSelectStringFor: nil, row: 2) == "c.swift")
        #expect(controller.openSelection())
        #expect(recorder.opened == ["1"])

        // Choosing another file tells the model.
        table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(recorder.selected == ["2"])
    }

    // MARK: Sheets and tags

    @Test("the tag sheet: the newest three previous tags with the name typed, and Create only for a usable name that's free")
    func createTag() {
        let tags = ["v1.0", "v1.10", "v1.2", "v2.0-beta"]
        #expect(CreateTagContent.previousTags(tags, matching: "") == ["v2.0-beta", "v1.10", "v1.2"])
        #expect(CreateTagContent.previousTags(tags, matching: "1.1") == ["v1.10"])
        #expect(CreateTagContent(name: "", sanitizedName: "", error: nil, previousTags: []).canCreate == false)
        #expect(CreateTagContent(name: "release 1", sanitizedName: "release-1", error: nil, previousTags: []).canCreate)
        #expect(CreateTagContent(name: "v1.2", sanitizedName: "v1.2", error: "A tag named v1.2 already exists", previousTags: ["v1.2"]).canCreate == false)
    }

    @Test("Go to Commit takes four or more hex digits as a commit ID")
    func goToCommit() {
        #expect(GoToCommitForm.isCommitID("a1b2"))
        #expect(!GoToCommitForm.isCommitID("a1b"))
        #expect(!GoToCommitForm.isCommitID("main"))
    }

    @Test("tag rows: newest version first, filtered by name; a tag waits to be pushed only with a remote")
    func tagRows() {
        let rows = TagRowContent.rows(tags: ["v1.9", "v1.10", "beta", "v2.0"], tagsToPush: ["v2.0"], filter: "")
        #expect(rows.map(\.name) == ["v2.0", "v1.10", "v1.9", "beta"])
        #expect(TagRowContent.rows(tags: ["v1.9", "beta"], tagsToPush: [], filter: "BET").map(\.name) == ["beta"])
        #expect(rows.map(\.isWaitingToBePushed) == [true, false, false, false])
        // Without a remote, nothing waits to be pushed.
        #expect(TagRowContent.rows(tags: ["v2.0"], tagsToPush: ["v2.0"], hasRemote: false, filter: "").map(\.isWaitingToBePushed) == [false])
    }
}

/// What a file list told its model, in a test.
@MainActor
private final class FileListRecorder {
    var selected: [String?] = []
    var opened: [String] = []
    /// The files whose menu's item was chosen.
    var menuChosen: [String] = []
}
