// History's views, one image per layout: the header and search, Compare
// and its call to action, a commit's header and files (and ⇧F10 on them),
// a range and its reachability, commits that aren't adjacent, the working
// copy, Commit Info, the tag and Go to Commit sheets, keyboard reorder's
// hint, and tag rows. Compare and the commit's header in light and dark,
// the rest in light; states that differ only in words are content
// assertions. Leaf views take values, so these need no repository.

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

    // MARK: Compare

    @Test("Compare: Behind with each status, and Ahead")
    func compare() {
        func header(_ direction: ComparisonDirection, _ cta: MergeCallToActionContent?) -> some View {
            CompareHeader(content: CompareHeaderContent(
                branchName: "feature/login",
                direction: direction,
                behindTitle: "Behind (3)",
                aheadTitle: "Ahead (2)",
                isLoading: false,
                callToAction: cta
            ))
        }
        let views = VStack(spacing: 0) {
            header(.behind, MergeCallToActionContent(method: .merge, status: .loading, message: "Checking whether Git can merge automatically…", canStart: true))
            Divider()
            header(.behind, MergeCallToActionContent(method: .merge, status: .clean, message: "This will merge 3 commits from feature/login into main", canStart: true))
            Divider()
            header(.behind, MergeCallToActionContent(method: .squashMerge, status: .conflicts, message: "There will be 2 conflicted files when merging feature/login into main", canStart: true))
            Divider()
            header(.behind, MergeCallToActionContent(method: .merge, status: .invalid, message: "These branches have unrelated histories and can't be merged", canStart: false))
            Divider()
            header(.behind, MergeCallToActionContent(method: .rebase, status: .clean, message: "This will update main by applying its 2 commits on top of feature/login", canStart: true))
            Divider()
            header(.ahead, nil)
        }
        assertSnapshot(views.frame(width: width), named: "compare", area: area)
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

    @Test("a commit's files: the label with the count and lines, then chips (the selected one tinted, wrapping), or rows for many")
    func commitFiles() {
        let rows = [
            CommittedFileRowContent(id: "1", path: "Sources/App/RepositoryLoader.swift", status: .modified),
            CommittedFileRowContent(id: "2", path: "Sources/App/EmptyState.swift", status: .new),
            CommittedFileRowContent(id: "3", path: "Legacy.swift", status: .deleted),
            CommittedFileRowContent(id: "4", path: "Sources/App/Loader.swift", oldPath: "Sources/Old/Loader.swift", status: .renamed),
            CommittedFileRowContent(id: "5", path: "Resources/icon.png", status: .modified),
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
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                CommitFilesHeader(summary: CommitFilesSummary(fileCount: 5, linesAdded: 22, linesDeleted: 43))
                HistoryFiles(files: files, selection: "1")
            }
            .padding(Metrics.insetLarge)
            Hairline()
            HistoryFiles(files: files, selection: "4", style: .rows)
                .frame(width: Metrics.Column.commitFileList.ideal + 60, height: 180)
        }
        assertSnapshot(view.frame(width: 440), named: "commitFiles", area: area)
        #expect(CommitFilesSummary(fileCount: 1, linesAdded: 0, linesDeleted: 0).title == "1 changed file")
        // Chips up to 40 files; rows past that.
        #expect(HistoryFilesStyle.style(forFileCount: 40) == .chips)
        #expect(HistoryFilesStyle.style(forFileCount: 41) == .rows)
        // The arrow keys move to the next or previous file, staying at the
        // ends, and start at the first; typing selects by name.
        #expect(HistoryFilesNavigation.file(after: "2", step: 1, in: files) == "3")
        #expect(HistoryFilesNavigation.file(after: "2", step: -1, in: files) == "1")
        #expect(HistoryFilesNavigation.file(after: "5", step: 1, in: files) == "5")
        #expect(HistoryFilesNavigation.file(after: "1", step: -1, in: files) == "1")
        #expect(HistoryFilesNavigation.file(after: nil, step: 1, in: files) == "1")
        #expect(HistoryFilesNavigation.file(after: nil, step: 1, in: []) == nil)
        #expect(HistoryFilesNavigation.file(named: "le", in: files) == "3")
        #expect(HistoryFilesNavigation.file(named: "LOA", in: files) == "4")
        #expect(HistoryFilesNavigation.file(named: "zz", in: files) == nil)
    }

    @Test("⇧F10 on a commit's files pops up the selected file's menu, at the file, as chips and as rows")
    func filesKeyboardMenu() throws {
        let files = ["a.swift", "b.swift", "c.swift"].enumerated().map { index, path in
            HistoryFileContent(file: CommittedFileRowContent(id: "\(index)", path: path, status: .modified))
        }
        for style in [HistoryFilesStyle.chips, .rows] {
            let view = HistoryFiles(files: files, selection: "1", style: style) { file in
                Button("Open \(file.file.fileName)") {}
            }
            let (window, host) = hostInWindow(view.frame(width: 400, height: 200), size: CGSize(width: 400, height: 200))
            defer { window.contentView = nil }
            let anchor = try #require(firstView(KeyboardMenuAnchorView.AnchorView.self, in: host))
            let popped = PoppedUpMenus()
            #expect(KeyboardContextMenu.showMenu(of: anchor, present: popped.present))
            #expect(popped.popups.first?.titles == ["Open b.swift"])
        }
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

    @Test("Commit Info: message with a link, author, committer, SHA, parents, refs, co-authors, trailers")
    func commitInfo() {
        let content = CommitInfoContent(
            sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            summary: "Merge pull request #142 from joe/sign-in",
            body: "Add the sign-in sheet. See https://example.com/issues/142 for the design.",
            author: .init(name: "Joe Bloggs", email: "joe@example.com", date: UIFixtures.minutesAgo(120)),
            committer: .init(name: "GitHub", email: "noreply@github.com", date: UIFixtures.minutesAgo(90)),
            avatarEndpoint: nil,
            parents: [.init(sha: "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1", summary: "Bump version"), .init(sha: "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2", summary: nil)],
            refs: [RefCapsuleContent(name: "main", kind: .currentBranch, track: 0), RefCapsuleContent(name: "v1.2", kind: .tag, track: 0)],
            coAuthors: ["Mary Jane <mary@example.com>"],
            trailers: [.init(token: "Signed-off-by", value: "Joe Bloggs <joe@example.com>")],
            underlinesLinks: true
        )
        #expect(content.message.runs.contains { $0.link != nil })
        assertSnapshot(
            CommitInfoView(content: content),
            named: "commitInfo",
            area: area,
            size: CGSize(width: Metrics.Column.inspector.ideal, height: 760),
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
