// History's views, one image per layout: the header and search, a branch's
// header and Compare's call to action, a place's notice, a commit's header
// and files (and the keys on them), a range and its reachability, commits
// that aren't adjacent, the working copy, Commit Info, the tag and Go to
// Commit sheets, keyboard reorder's hint, and tag rows. The branch's header
// and the commit's header in light and dark, the rest in light; states that
// differ only in words are content assertions. Leaf views take values, so
// these need no repository.

import AppKit
@testable import EspalierCore
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History views") @MainActor
struct HistoryViewSnapshotTests {
    private let area = "History"
    private let width: CGFloat = 520

    // MARK: Header and search

    @Test("the header: Simple with its branch, and Graph with the scope and the count, complete and paging")
    func header() {
        let views = VStack(spacing: 0) {
            HistoryHeader(content: HistoryHeaderContent(style: .simple, scope: .localBranches, count: "", branchName: "feature/hourly-forecast"))
            Hairline()
            HistoryHeader(content: HistoryHeaderContent(scope: .localBranches, count: HistoryHeaderContent.count(loaded: 1_204, total: 1_204, isComplete: true)))
            Hairline()
            HistoryHeader(content: HistoryHeaderContent(scope: .allBranches, count: HistoryHeaderContent.count(loaded: 1_100, total: nil, isComplete: false)))
        }
        assertSnapshot(views.frame(width: width), named: "header", area: area)
        #expect(HistoryHeaderContent.count(loaded: 1_100, total: nil, isComplete: false) == "1,100+ commits")
        #expect(HistoryHeaderContent.count(loaded: 1, total: nil, isComplete: true) == "1 commit")
        #expect(HistoryHeaderContent.count(loaded: 0, total: nil, isComplete: true) == "No commits")
        #expect(HistoryHeaderContent.count(loaded: 100, total: 40_162, isComplete: false) == "40,162 commits")
    }

    @Test("the search: matches, the match moved to, none, older commits, and a SHA")
    func search() {
        var matches = HistorySearch(query: "fix")
        matches.matchingRows = [3, 9, 40]
        matches.isSearching = false
        var moved = matches
        moved.currentMatch = 1
        var none = HistorySearch(query: "nothing")
        none.isSearching = false
        var sha = HistorySearch(query: "a1b2c3d4")
        sha.isSearching = false
        let contents = [
            HistorySearchStatusContent(search: matches, loaded: 2_400, isComplete: false, isLoadingMore: false),
            HistorySearchStatusContent(search: moved, loaded: 2_400, isComplete: true, isLoadingMore: false),
            HistorySearchStatusContent(search: none, loaded: 2_400, isComplete: false, isLoadingMore: true),
            HistorySearchStatusContent(search: sha, loaded: 2_400, isComplete: false, isLoadingMore: false),
        ]
        #expect(contents[0].text == "3 matches in 2,400 loaded commits")
        #expect(contents[1].text == "2 of 3 matches in 2,400 loaded commits")
        #expect(contents[2].text == "No matches in 2,400 loaded commits")
        #expect(contents[3].shortCommitID == "a1b2c3d")
        let views = VStack(spacing: 0) {
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                HistoryHeader(content: HistoryHeaderContent(scope: .localBranches, count: "", search: content))
                Hairline()
            }
        }
        assertSnapshot(views.frame(width: width), named: "search", area: area, appearances: [.light])
    }

    // MARK: A branch's place

    @Test("a branch's header: History, Behind with each status of the call to action, Ahead, and on a detached HEAD")
    func branchHeader() {
        func header(_ view: BranchView, _ cta: MergeCallToActionContent?, canCompare: Bool) -> some View {
            BranchHeader(content: BranchHeaderContent(
                branchName: "feature/login",
                view: view,
                behind: 3,
                ahead: 2,
                canCompare: canCompare,
                callToAction: cta
            ))
        }
        let views = VStack(spacing: 0) {
            header(.history, nil, canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .loading, message: "Checking whether Git can merge automatically…", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .clean, message: "This will merge 3 commits from feature/login into main", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .squashMerge, status: .conflicts, message: "There will be 2 conflicted files when merging feature/login into main", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .invalid, message: "These branches have unrelated histories and can't be merged", canStart: false), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .rebase, status: .clean, message: "This will update main by applying its 2 commits on top of feature/login", canStart: true), canCompare: true)
            Divider()
            header(.compare(.ahead), nil, canCompare: true)
            Divider()
            header(.history, nil, canCompare: false)
        }
        assertSnapshot(views.frame(width: width), named: "branchHeader", area: area)
        // In the simple list's narrow column the views go under the name.
        assertSnapshot(header(.history, nil, canCompare: true).frame(width: Metrics.Column.simpleList.min), named: "branchHeader-narrow", area: area, appearances: [.light])
        let uncounted = BranchHeaderContent(branchName: "feature/login", view: .history, canCompare: true)
        #expect(uncounted.behindTitle == "Behind")
        #expect(uncounted.aheadTitle == "Ahead")
        #expect(BranchHeaderContent(branchName: "x", view: .history, behind: 1_204, ahead: 0, canCompare: true).behindTitle == "Behind (1,204)")
    }

    @Test("a place's notice: a tag off the simple list's line, and a branch outside the graph's scope")
    func placeNotice() {
        let offLine = HistoryPlaceNotice(place: .tag(name: "v1.0"), name: "v1.0", kind: .notOnLine(branch: "main"))
        let outside = HistoryPlaceNotice(place: .branch(ref: "refs/remotes/origin/fix"), name: "origin/fix", kind: .outsideScope(.localBranches))
        #expect(String(offLine.message.characters) == "v1.0 isn\u{2019}t in main\u{2019}s history.")
        #expect(offLine.actionTitle == "Show in Graph")
        #expect(String(outside.message.characters) == "origin/fix isn\u{2019}t in the graph, which shows Local Branches.")
        #expect(outside.actionTitle == "Show All Branches")
        // All Branches reaches every branch and tag: nothing more to show.
        #expect(HistoryPlaceNotice(place: .tag(name: "v1.0"), name: "v1.0", kind: .outsideScope(.allBranches)).actionTitle == nil)
        let views = VStack(spacing: 0) {
            HistoryNoticeBanner(notice: offLine)
            HistoryNoticeBanner(notice: outside)
        }
        assertSnapshot(views.frame(width: Metrics.Column.simpleList.ideal), named: "placeNotice", area: area, appearances: [.light])
    }

    // MARK: The commit detail

    private var commitHeader: CommitHeaderContent {
        CommitHeaderContent(
            sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            summary: "Fix crash when opening an empty repository",
            description: "The empty-repository path dereferenced a nil tip, which crashed on launch for new repositories. Load an empty history instead and show the working copy alone.",
            authorName: "Joe Bloggs",
            authorEmail: "joe@example.com",
            avatarEndpoint: nil,
            date: UIFixtures.minutesAgo(120),
            tags: [
                RefCapsuleContent(name: "v1.2", kind: .tag, track: 0),
            ]
        )
    }

    @Test("a commit's header, and one with an empty message")
    func commitHeaders() {
        var empty = commitHeader
        empty.summary = ""
        empty.description = ""
        empty.tags = []
        let views = VStack(spacing: 0) {
            CommitHeader(content: commitHeader, palette: TrackPalette.Resolved(currentTrack: 0))
                .padding(Metrics.insetLarge)
            Hairline()
            CommitHeader(content: empty)
                .padding(Metrics.insetLarge)
        }
        assertSnapshot(views.frame(width: 640), named: "commitHeader", area: area)
    }

    @Test("a commit's header shows emoji, and links issue references, mentions, and URLs")
    func commitHeaderRichText() {
        var rich = commitHeader
        rich.summary = "Fix #12 :tada: thanks @octocat"
        rich.description = "Follows up :bug: https://github.com/octo/app/issues/7 (see https://example.com/notes).\n\nCo-authored by @hubot, who found it."
        rich.gitHubRepository = gitHubRepoFixture(owner: "octo", name: "app")
        var plain = rich
        plain.gitHubRepository = nil
        plain.underlinesLinks = false
        #expect(String(rich.richSummary.characters) == "Fix #12 \u{1F389} thanks @octocat")
        #expect(rich.richSummary.runs.compactMap(\.link).map(\.absoluteString) == ["https://github.com/octo/app/issues/12", "https://github.com/octocat"])
        #expect(plain.richSummary.runs.compactMap(\.link).isEmpty)
        let views = VStack(spacing: 0) {
            CommitHeader(content: rich)
                .padding(Metrics.insetLarge)
            Hairline()
            CommitHeader(content: plain)
                .padding(Metrics.insetLarge)
        }
        assertSnapshot(views.frame(width: 640), named: "commitHeader-richText", area: area, appearances: [.light])
    }

    @Test("a commit's files beside the diff: the label with the count and lines, then a row each with its folder, the selected one tinted")
    func commitFiles() {
        let rows = [
            CommittedFileRowContent(id: "1", path: "Sources/App/RepositoryLoader.swift", status: .modified),
            CommittedFileRowContent(id: "2", path: "Sources/App/EmptyState.swift", status: .new),
            CommittedFileRowContent(id: "3", path: "Legacy.swift", status: .deleted),
            CommittedFileRowContent(id: "4", path: "Sources/App/Loader.swift", oldPath: "Sources/Old/Loader.swift", status: .renamed),
            CommittedFileRowContent(id: "5", path: "Resources/icon.png", status: .modified),
            // Two files of one name tell apart by their folders.
            CommittedFileRowContent(id: "6", path: "web/src/index.ts", status: .modified),
            CommittedFileRowContent(id: "7", path: "web/test/index.ts", status: .modified),
        ]
        #expect(rows[3].tooltip == "Sources/Old/Loader.swift → Sources/App/Loader.swift")
        #expect(rows[2].directory == "")
        let files = [
            HistoryFileContent(file: rows[0], added: 6, deleted: 1),
            HistoryFileContent(file: rows[1], added: 14, deleted: 0),
            HistoryFileContent(file: rows[2], added: 0, deleted: 40),
            HistoryFileContent(file: rows[3], added: 2, deleted: 2),
            // A binary file: no counts.
            HistoryFileContent(file: rows[4]),
            HistoryFileContent(file: rows[5], added: 3, deleted: 1),
            HistoryFileContent(file: rows[6], added: 12, deleted: 0),
        ]
        #expect(files[0].accessibilityLabel == "RepositoryLoader.swift, Modified, in Sources/App, 6 added lines, 1 removed line")
        #expect(files[2].accessibilityLabel == "Legacy.swift, Deleted, 40 removed lines")
        #expect(files[3].accessibilityLabel == "Loader.swift, Renamed, from Sources/Old/Loader.swift, 2 added lines, 2 removed lines")
        #expect(files[4].accessibilityLabel == "icon.png, Modified, in Resources")
        let view = VStack(spacing: 0) {
            CommitFilesHeader(summary: CommitFilesSummary(fileCount: 7, linesAdded: 37, linesDeleted: 44))
            Hairline()
            HistoryFileList(files: files, selection: "4")
        }
        assertSnapshot(view.frame(width: Metrics.Column.commitFileList.ideal, height: 300), named: "commitFiles", area: area)
        #expect(CommitFilesSummary(fileCount: 1, linesAdded: 0, linesDeleted: 0).title == "1 changed file")
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
                    MenuAction("Open \(id)") {}
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
        #expect(menus.popups.first?.titles == ["Open 1"])
        #expect(table.contextMenuTarget.row == 1)
        menus.popups.first?.close()
        #expect(ContextMenuRegions.openMenu(for: try rightClick(row: 2, in: table), presenter: menus.menuPresenter))
        #expect(menus.popups.last?.titles == ["Open 2"])
        #expect(table.contextMenuTarget.row == 2)
        #expect(table.selectedRow == 1)

        #expect(controller.tableView(table, typeSelectStringFor: nil, row: 2) == "c.swift")
        #expect(controller.openSelection())
        #expect(recorder.opened == ["1"])

        // Choosing another file tells the model.
        table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(recorder.selected == ["2"])
    }

    @Test("a range: the commits in its diff, those left out, and the reachability popover's unreachable tab")
    func range() {
        let content = RangeSummaryContent(
            reachable: [CommitLine(sha: "a1b2c3d4", summary: "Wire device flow"), CommitLine(sha: "b2c3d4e5", summary: "Add sign-in sheet"), CommitLine(sha: "c3d4e5f6", summary: "Bump version")],
            unreachable: [CommitLine(sha: "d4e5f6a7", summary: "Update docs"), CommitLine(sha: "e5f6a7b8", summary: "Refactor loader")]
        )
        #expect(content.title == "Showing changes from 3 commits")
        #expect(content.unreachableTitle == "2 unreachable commits")
        assertSnapshot(RangeSummary(content: content).padding(Metrics.insetLarge).frame(width: width), named: "range", area: area, appearances: [.light])
        assertSnapshot(UnreachableCommitsPopover(content: content), named: "reachability-unreachable", area: area, appearances: [.light])
    }

    @Test("commits that aren't adjacent show what can be done instead")
    func nonContiguous() {
        assertSnapshot(NonContiguousView(), named: "nonContiguous", area: area, size: CGSize(width: width, height: 340), appearances: [.light])
    }

    @Test("the working copy's header: changes, conflicts, and none")
    func workingCopy() {
        let views = VStack(spacing: 0) {
            WorkingCopyHeader(content: WorkingCopyHeaderContent(summary: WorkingCopySummary(changedFiles: 3)))
                .padding(Metrics.insetLarge)
            Hairline()
            WorkingCopyHeader(content: WorkingCopyHeaderContent(summary: WorkingCopySummary(changedFiles: 4, conflictedFiles: 2)))
                .padding(Metrics.insetLarge)
            Hairline()
            WorkingCopyHeader(content: WorkingCopyHeaderContent(summary: WorkingCopySummary()))
                .padding(Metrics.insetLarge)
        }
        assertSnapshot(views.frame(width: width), named: "workingCopy", area: area, appearances: [.light])
    }

    // MARK: Commit Info

    @Test("Commit Info: when it was authored and committed and by whom, parents, branches, co-authors, trailers")
    func commitInfo() {
        let content = CommitInfoContent(
            authorEmail: "joe@example.com",
            authoredDate: UIFixtures.minutesAgo(120),
            committer: .init(name: "GitHub", email: "noreply@github.com"),
            committedDate: UIFixtures.minutesAgo(90),
            parents: [.init(sha: "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1", summary: "Bump version"), .init(sha: "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2", summary: nil)],
            branches: [RefCapsuleContent(name: "main", kind: .currentBranch, track: 0)],
            coAuthors: ["Mary Jane <mary@example.com>"],
            trailers: [.init(token: "Signed-off-by", value: "Joe Bloggs <joe@example.com>")]
        )
        assertSnapshot(
            CommitInfoView(content: content),
            named: "commitInfo",
            area: area,
            size: CGSize(width: Metrics.Column.inspector.ideal, height: 420),
            appearances: [.light]
        )
    }

    // MARK: Sheets and hints

    @Test("the tag sheet: empty, a name cleaned up, and a name taken, which is drawn")
    func createTag() {
        let tags = ["v1.0", "v1.10", "v1.2", "v2.0-beta"]
        #expect(CreateTagContent.previousTags(tags, matching: "") == ["v2.0-beta", "v1.10", "v1.2"])
        #expect(CreateTagContent.previousTags(tags, matching: "1.1") == ["v1.10"])
        let states = [
            ("empty", CreateTagContent(name: "", sanitizedName: "", error: nil, previousTags: CreateTagContent.previousTags(tags, matching: ""))),
            ("sanitized", CreateTagContent(name: "release 1", sanitizedName: "release-1", error: nil, previousTags: [])),
            ("taken", CreateTagContent(name: "v1.2", sanitizedName: "v1.2", error: "A tag named v1.2 already exists", previousTags: ["v1.2"])),
        ]
        let taken = states[2].1
        assertSnapshot(CreateTagForm(content: taken, name: .constant(taken.name)), named: "createTag-taken", area: area, appearances: [.light])
        #expect(states[0].1.canCreate == false)
        #expect(states[1].1.canCreate)
        #expect(states[2].1.canCreate == false)
    }

    @Test("Go to Commit: not found is drawn; empty, searching, and not in the history differ only in words")
    func goToCommit() {
        #expect(GoToCommitForm.isCommitID("a1b2"))
        #expect(!GoToCommitForm.isCommitID("a1b"))
        #expect(!GoToCommitForm.isCommitID("main"))
        assertSnapshot(
            GoToCommitForm(text: .constant("a1b2c3d"), status: .notFound("a1b2c3d")),
            named: "goToCommit-notFound",
            area: area,
            appearances: [.light]
        )
    }

    @Test("keyboard reorder's hint, and tag rows with one selected")
    func hintAndTags() {
        assertSnapshot(KeyboardReorderHint(count: 2).padding(Metrics.insetLarge), named: "reorderHint", area: area, appearances: [.light])
        let rows = TagRowContent.rows(tags: ["v1.9", "v1.10", "beta", "v2.0"], tagsToPush: ["v2.0"], filter: "")
        #expect(rows.map(\.name) == ["v2.0", "v1.10", "v1.9", "beta"])
        #expect(TagRowContent.rows(tags: ["v1.9", "beta"], tagsToPush: [], filter: "BET").map(\.name) == ["beta"])
        #expect(rows.map(\.isWaitingToBePushed) == [true, false, false, false])
        // Without a remote, nothing waits to be pushed.
        #expect(TagRowContent.rows(tags: ["v2.0"], tagsToPush: ["v2.0"], hasRemote: false, filter: "").map(\.isWaitingToBePushed) == [false])
        // As the sidebar lists them, v1.10 selected: the neutral wash, its
        // name medium, and its symbol in the accent.
        let list = List {
            ForEach(rows) { row in
                TagRow(content: row)
                    .sidebarRow(.tag(name: row.name))
            }
        }
        .sidebarListStyle()
        .environment(\.sidebarSelection, .tag(name: "v1.10"))
        assertSnapshot(list.frame(width: 220, height: 130), named: "tags", area: area, appearances: [.light])
    }
}

/// What a file list told its model, in a test.
@MainActor
private final class FileListRecorder {
    var selected: [String?] = []
    var opened: [String] = []
}
