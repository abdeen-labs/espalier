// History's views, one capture per layout: the header and search, a
// branch's header with its call to action and the call to action's split
// button, a place's notice, a commit's header and files, a range and its
// reachability, commits that aren't adjacent, the working copy, Commit
// Info, the tag and Go to Commit sheets, keyboard reorder's hint, tag rows,
// and the image a drag of commits shows. Leaf views take values, so these
// need no repository.

import AppKit
@testable import EspalierCore
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History views", .captures) @MainActor
struct HistoryViewCaptures {
    private let area = "History"
    private let width: CGFloat = 520

    // MARK: Header and search

    @Test("the header: Simple with its branch, and Graph with the scope and the count, complete and paging")
    func header() {
        let views = VStack(spacing: 0) {
            HistoryHeader(content: HistoryHeaderContent(style: .simple, scope: .localBranches, count: "", branchName: "feature/hourly-forecast"))
            Hairline()
            HistoryHeader(content: HistoryHeaderContent(
                scope: .localBranches,
                count: HistoryHeaderContent.count(loaded: 1_204, total: 1_204, isComplete: true, numberFormat: Capture.numberFormat)
            ))
            Hairline()
            HistoryHeader(content: HistoryHeaderContent(
                scope: .allBranches,
                count: HistoryHeaderContent.count(loaded: 1_100, total: nil, isComplete: false, numberFormat: Capture.numberFormat)
            ))
        }
        capture(views.frame(width: width), named: "header", area: area)
    }

    @Test("the search: matches, the match moved to, none while older commits load, and a SHA")
    func search() {
        var matches = HistorySearch(query: "fix")
        matches.matchingRows = [3, 9, 40]
        matches.isSearching = false
        var moved = matches
        moved.current = .row(9)
        var none = HistorySearch(query: "nothing")
        none.isSearching = false
        var sha = HistorySearch(query: "a1b2c3d4")
        sha.isSearching = false
        let contents = [
            HistorySearchStatusContent(search: matches, loaded: 2_400, isComplete: false, isLoadingMore: false, numberFormat: Capture.numberFormat),
            HistorySearchStatusContent(search: moved, loaded: 2_400, isComplete: true, isLoadingMore: false, numberFormat: Capture.numberFormat),
            HistorySearchStatusContent(search: none, loaded: 2_400, isComplete: false, isLoadingMore: true, numberFormat: Capture.numberFormat),
            HistorySearchStatusContent(search: sha, loaded: 2_400, isComplete: false, isLoadingMore: false, numberFormat: Capture.numberFormat),
        ]
        let views = VStack(spacing: 0) {
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                HistoryHeader(content: HistoryHeaderContent(scope: .localBranches, count: "", search: content))
                Hairline()
            }
        }
        capture(views.frame(width: width), named: "search", area: area)
    }

    // MARK: A branch's place

    @Test("a branch's header, compared with main: History, Behind with each status of the call to action, Ahead, and on a detached HEAD")
    func branchHeader() {
        func header(
            _ view: BranchView,
            _ cta: MergeCallToActionContent?,
            canCompare: Bool,
            comparedWith: String = "main",
            behind: Int = 3,
            ahead: Int = 2
        ) -> some View {
            BranchHeader(content: BranchHeaderContent(
                branchName: "feature/login",
                view: view,
                behind: behind,
                ahead: ahead,
                comparedWith: canCompare ? comparedWith : nil,
                callToAction: cta,
                numberFormat: Capture.numberFormat
            ))
        }
        let views = VStack(spacing: 0) {
            header(.history, nil, canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .loading, message: "Checking whether Git can merge automatically…", canStart: false), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .clean, message: "This will merge 3 commits from feature/login into main", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .squashMerge, status: .conflicts, message: "There will be 2 conflicted files when merging feature/login into main", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .invalid, message: "These branches have unrelated histories and can't be merged", canStart: false), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .merge, status: .unknown, message: "Couldn't check whether this merges cleanly", canStart: true), canCompare: true)
            Divider()
            header(.compare(.behind), MergeCallToActionContent(method: .rebase, status: .clean, message: "This will update main by applying its 2 commits on top of feature/login", canStart: true), canCompare: true)
            Divider()
            header(.compare(.ahead), nil, canCompare: true)
            Divider()
            header(.history, nil, canCompare: true, behind: 1_204, ahead: 12_317)
            Divider()
            header(.history, nil, canCompare: false)
        }
        capture(views.frame(width: width), named: "branchHeader", area: area)
        // In the simple list's narrow column the views go under the name; a
        // long current branch's name cuts the caption.
        let narrow = VStack(spacing: 0) {
            header(.history, nil, canCompare: true)
            Divider()
            header(.history, nil, canCompare: true, comparedWith: "feature/hourly-forecast-for-the-whole-week")
        }
        capture(narrow.frame(width: Metrics.Column.simpleList.min), named: "branchHeader-narrow", area: area)
    }

    @Test("the call to action's split button: each method, ready to start, and not (the menu still switches the method)")
    func mergeButton() {
        let view = VStack(alignment: .trailing, spacing: Metrics.insetMedium) {
            ForEach(CompareMethod.allCases) { method in
                HStack(spacing: Metrics.insetMedium) {
                    MergeMethodButton(method: .constant(method), canStart: true, start: {})
                    MergeMethodButton(method: .constant(method), canStart: false, start: {})
                }
            }
        }
        .padding(Metrics.insetLarge)
        capture(view, named: "mergeButton", area: area)
    }

    @Test("a place's notice: a tag off the simple list's line, and a branch outside the graph's scope")
    func placeNotice() {
        let views = VStack(spacing: 0) {
            HistoryNoticeBanner(notice: HistoryPlaceNotice(place: .tag(name: "v1.0"), name: "v1.0", kind: .notOnLine(branch: "main")))
            HistoryNoticeBanner(notice: HistoryPlaceNotice(place: .branch(ref: "refs/remotes/origin/fix"), name: "origin/fix", kind: .outsideScope(.localBranches)))
        }
        capture(views.frame(width: Metrics.Column.simpleList.ideal), named: "placeNotice", area: area)
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
            date: Date.now.addingTimeInterval(-2 * 3_600),
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
        capture(views.frame(width: 640), named: "commitHeader", area: area)
    }

    @Test("a commit's header shows emoji, and links issue references, mentions, and URLs, underlined or not")
    func commitHeaderRichText() {
        var rich = commitHeader
        rich.summary = "Fix #12 :tada: thanks @octocat"
        rich.description = "Follows up :bug: https://github.com/octo/app/issues/7 (see https://example.com/notes).\n\nCo-authored by @hubot, who found it."
        rich.gitHubRepository = gitHubRepoFixture(owner: "octo", name: "app")
        var plain = rich
        plain.gitHubRepository = nil
        plain.underlinesLinks = false
        let views = VStack(spacing: 0) {
            CommitHeader(content: rich)
                .padding(Metrics.insetLarge)
            Hairline()
            CommitHeader(content: plain)
                .padding(Metrics.insetLarge)
        }
        capture(views.frame(width: 640), named: "commitHeader-richText", area: area)
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
        let files = [
            HistoryFileContent(file: rows[0], added: 6, deleted: 1, numberFormat: Capture.numberFormat),
            HistoryFileContent(file: rows[1], added: 14, deleted: 0, numberFormat: Capture.numberFormat),
            HistoryFileContent(file: rows[2], added: 0, deleted: 4, numberFormat: Capture.numberFormat),
            HistoryFileContent(file: rows[3], added: 2, deleted: 2, numberFormat: Capture.numberFormat),
            // A binary file: no counts.
            HistoryFileContent(file: rows[4], numberFormat: Capture.numberFormat),
            HistoryFileContent(file: rows[5], added: 3, deleted: 1, numberFormat: Capture.numberFormat),
            HistoryFileContent(file: rows[6], added: 12, deleted: 0, numberFormat: Capture.numberFormat),
        ]
        let view = VStack(spacing: 0) {
            CommitFilesHeader(summary: CommitFilesSummary(fileCount: 7, linesAdded: 37, linesDeleted: 8))
            Hairline()
            HistoryFileList(files: files, selection: "4")
        }
        capture(view.frame(width: Metrics.Column.commitFileList.ideal, height: 300), named: "commitFiles", area: area)
    }

    @Test("a range: the commits in its diff, those left out, and the reachability popover's unreachable tab")
    func range() {
        let content = RangeSummaryContent(
            reachable: [CommitLine(sha: "a1b2c3d4", summary: "Wire device flow"), CommitLine(sha: "b2c3d4e5", summary: "Add sign-in sheet"), CommitLine(sha: "c3d4e5f6", summary: "Bump version")],
            unreachable: [CommitLine(sha: "d4e5f6a7", summary: "Update docs"), CommitLine(sha: "e5f6a7b8", summary: "Refactor loader")]
        )
        capture(RangeSummary(content: content).padding(Metrics.insetLarge).frame(width: width), named: "range", area: area)
        capture(UnreachableCommitsPopover(content: content), named: "reachability-unreachable", area: area)
    }

    @Test("commits that aren't adjacent show what can be done instead")
    func nonContiguous() {
        capture(NonContiguousView(), named: "nonContiguous", area: area, size: CGSize(width: width, height: 340))
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
        capture(views.frame(width: width), named: "workingCopy", area: area)
    }

    // MARK: Commit Info

    @Test("Commit Info: when it was authored and committed and by whom, parents, branches, co-authors, trailers")
    func commitInfo() {
        let content = CommitInfoContent(
            authorEmail: "joe@example.com",
            authoredDate: Date.now.addingTimeInterval(-2 * 3_600),
            committer: .init(name: "GitHub", email: "noreply@github.com"),
            committedDate: Date.now.addingTimeInterval(-90 * 60),
            parents: [.init(sha: "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1", summary: "Bump version"), .init(sha: "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2", summary: nil)],
            branches: [RefCapsuleContent(name: "main", kind: .currentBranch, track: 0)],
            coAuthors: ["Mary Jane <mary@example.com>"],
            trailers: [
                .init(token: "Signed-off-by", value: "Joe Bloggs <joe@example.com>"),
                // Too wide: one line, its middle cut.
                .init(token: "Reviewed-by", value: "Maximilian Featherstonehaugh <maximilian.featherstonehaugh@example.com>"),
                // Free text wraps.
                .init(token: "Fixes", value: "the crash when a repository's only remote has no URL and the window opens"),
            ]
        )
        capture(
            CommitInfoView(content: content),
            named: "commitInfo",
            area: area,
            size: CGSize(width: Metrics.Column.inspector.ideal, height: 420)
        )
    }

    // MARK: Sheets and hints

    @Test("the tag sheet with a name that's taken")
    func createTag() {
        let taken = CreateTagContent(name: "v1.2", sanitizedName: "v1.2", error: "A tag named v1.2 already exists", previousTags: ["v1.2"])
        capture(CreateTagForm(content: taken, name: .constant(taken.name)), named: "createTag-taken", area: area)
    }

    @Test("the tag sheet with a name inside a tag's")
    func createTagClash() {
        let clash = CreateTagContent(
            name: "v1.2/rc",
            sanitizedName: "v1.2/rc",
            error: "A tag named v1.2 already exists, so v1.2/rc can't be used",
            previousTags: ["v1.2"]
        )
        capture(CreateTagForm(content: clash, name: .constant(clash.name)), named: "createTag-clash", area: area)
    }

    @Test("the tag sheet with a name git refuses")
    func createTagInvalid() {
        let name = "HEAD"
        let invalid = CreateTagContent(
            name: name,
            sanitizedName: sanitizedRefName(name),
            error: CreateTagContent.invalidNameError(name),
            previousTags: []
        )
        capture(CreateTagForm(content: invalid, name: .constant(name)), named: "createTag-invalid", area: area)
    }

    @Test("Go to Commit when no commit matches")
    func goToCommit() {
        capture(
            GoToCommitForm(text: .constant("a1b2c3d"), status: .notFound("a1b2c3d")),
            named: "goToCommit-notFound",
            area: area
        )
    }

    @Test("keyboard reorder's hint, and tag rows with one selected")
    func hintAndTags() {
        capture(KeyboardReorderHint(count: 2).padding(Metrics.insetLarge), named: "reorderHint", area: area)
        let rows = TagRowContent.rows(tags: ["v1.9", "v1.10", "beta", "v2.0"], tagsToPush: ["v2.0"], filter: "")
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
        capture(list.frame(width: 220, height: 130), named: "tags", area: area)
    }

    // MARK: Dragging

    @Test("a drag of one commit: its row on a card; of several, stacked behind it with their count")
    func dragImage() {
        for (name, count) in [("dragImage-one", 1), ("dragImage-several", 12)] {
            EspalierCaptures.capture(named: name, area: area) { appearance in
                let rowSize = CGSize(width: 300, height: Metrics.Graph.rowHeight)
                let layout = CommitDragImage.Layout(rowSize: rowSize, count: count, numberFormat: Capture.numberFormat)
                let row = Capture.render(DragImageRow().frame(width: rowSize.width, height: rowSize.height), size: rowSize, appearance: appearance)
                let image = CommitDragImage.image(rowImage: row, layout: layout, appearance: appearance.appearance, scale: Capture.scale)
                let view = NSImageView(frame: CGRect(origin: .zero, size: layout.size))
                view.image = image
                view.imageScaling = .scaleNone
                return Capture.render(view, size: layout.size, appearance: appearance)
            }
        }
    }
}

/// A selected commit row, as the graph draws one: its node, its title,
/// and its time.
private struct DragImageRow: View {
    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Circle()
                .fill(Color(espalier: Palette.accent))
                .frame(width: 10, height: 10)
            Text("Fetch hourly data from the forecast API")
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("18h")
                .font(Typography.secondary)
                .foregroundStyle(.text3)
        }
        .padding(.horizontal, Metrics.insetMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(.accentSoft).padding(.horizontal, Metrics.grid))
    }
}
