// History on a real repository: the graph of every local branch with HEAD's
// commit selected, emoji in summaries, a branch's place with its history and
// its comparison, and a tag off the simple list's line; Compare to Branch's
// list; the Commit menu's rules (reset to a commit with only unpushed
// commits after it, checkout of another commit, revert in the history or
// Compare's Ahead, delete only tags not pushed) and context menus; no
// rewrites in another branch's place; keyboard reorder moving a commit in
// git; and refused drops.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A repository with a dated history, selected in an app, with a window.
@MainActor
struct HistoryScreenFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let local: Repository
    /// The commits by summary.
    let shas: [String: String]

    var history: HistoryModel {
        repository.history
    }

    /// Waits for the repository and its history to settle.
    func settle() async {
        await app.idle()
        await repository.operations.enrichmentIdle()
        await history.idle()
    }

    /// Shows `place` and waits for it.
    func show(_ place: SidebarPlace) async {
        context.state.select(place, in: repository.id)
        history.activate()
        await settle()
        await HistoryPlaces.enter(place, repository: repository, context: context)
        await settle()
    }
}

/// Runs git at a fixed author and committer date, after writing and adding
/// `path` (its contents are git's arguments' last word); returns HEAD's SHA.
@concurrent
func datedGit(_ repository: Repository, date: String, writing path: String?, _ args: [String]) async throws -> String {
    try await withGitEnvironment(["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) {
        if let path {
            let fullPath = POSIXPath.join(repository.path, path)
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
            try Data("\(args.last ?? path)\n".utf8).write(to: URL(filePath: fullPath))
            try await runGit(["add", "--", path], repository)
        }
        try await runGit(args, repository)
        return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
    }
}

/// `main`: Initial commit, Add loader (tagged v1.0), Update docs, a merge
/// of `feature/login` (Add sign-in sheet, Wire device flow, from Add
/// loader), Bump version (HEAD); `fix/crash` from Update docs with Fix
/// crash on empty repository. Commits are a day before the fixtures' clock,
/// half an hour apart; one file is changed but not committed.
@MainActor
func makeHistoryScreenFixture(dirty: Bool = true) async throws -> HistoryScreenFixture {
    let local = try setupEmptyRepository("main")
    var shas: [String: String] = [:]
    var minute = 0
    func nextDate() -> String {
        minute += 30
        return "\(Int(UIFixtures.now.timeIntervalSince1970) - 86_400 + minute * 60) +0000"
    }
    func commit(_ path: String, _ message: String) async throws {
        shas[message] = try await datedGit(local, date: nextDate(), writing: path, ["commit", "-q", "-m", message])
    }
    func merge(_ branch: String, _ message: String) async throws {
        shas[message] = try await datedGit(local, date: nextDate(), writing: nil, ["merge", "-q", "--no-ff", "-m", message, branch])
    }
    try await commit("README.md", "Initial commit")
    try await commit("Sources/Loader.swift", "Add loader")
    try await runGit(["tag", "v1.0"], local)
    try await runGit(["checkout", "-q", "-b", "feature/login"], local)
    try await commit("Sources/SignIn.swift", "Add sign-in sheet")
    try await commit("Sources/DeviceFlow.swift", "Wire device flow")
    try await runGit(["checkout", "-q", "main"], local)
    try await commit("docs/Guide.md", "Update docs")
    try await runGit(["checkout", "-q", "-b", "fix/crash"], local)
    try await commit("Sources/Empty.swift", "Fix crash on empty repository")
    try await runGit(["checkout", "-q", "main"], local)
    try await merge("feature/login", "Merge branch 'feature/login'")
    try await commit("VERSION", "Bump version")
    if dirty {
        try Data("Changed\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
    }

    let harness = try AppHarness()
    let app = await harness.loadedApp()
    app.preferences.hasShownWelcomeFlow = true
    let repository = try await harness.addAndSelect(local, to: app)
    let context = WindowContext(app: app)
    context.avatarLoader = MonogramAvatarLoader()
    return HistoryScreenFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: shas)
}

@Suite("History screen", .offline, .hangGuard(minutes: 5)) @MainActor
struct HistoryScreenTests {
    @Test("History graphs every local branch and selects HEAD's commit")
    func historyGraph() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            await fixture.show(.history)
            let history = fixture.history
            // The working copy, then the eight commits of main, the merged
            // feature, and fix/crash.
            #expect(history.graph.count == 9)
            #expect(history.selection.shas == [fixture.shas["Bump version"]!])

            // The details' author line shows a commit's tags, not its
            // branches (its row does).
            let tip = try #require(history.commit(fixture.shas["Bump version"]!))
            #expect(history.refs(at: tip.sha).map(\.name).contains("main"))
            #expect(CommitHeaderContent(tip, repository: fixture.repository, underlinesLinks: true).tags.isEmpty)
            let tagged = try #require(history.commit(fixture.shas["Add loader"]!))
            #expect(CommitHeaderContent(tagged, repository: fixture.repository, underlinesLinks: true).tags.map(\.name) == ["v1.0"])
            await fixture.settle()
        }
    }

    @Test("shortcodes in a commit's summary show as emoji: its row, its header, and Undo Commit")
    func emojiSummaries() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try setupEmptyRepository("main")
            try Data("a\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "a.txt")))
            try await runGit(["add", "--", "a.txt"], local)
            try await runGit(["commit", "-q", "-m", ":bug: Fix the loader :tada:", "-m", "Found by :mag: https://example.com"], local)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            let context = WindowContext(app: app)
            let fixture = HistoryScreenFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: [:])
            await fixture.show(.history)
            let commit = try #require(fixture.history.commit(atRow: 1))
            #expect(commit.summary == ":bug: Fix the loader :tada:")

            let controller = GraphTableController()
            controller.update(source: fixture.history, presentation: GraphPresentation(repository: repository, place: .history), selection: GraphSelection(), reorderInsertionRow: nil)
            #expect(controller.content(forRow: 1).summary == "\u{1F41B} Fix the loader \u{1F389}")
            let header = CommitHeaderContent(commit, repository: repository, underlinesLinks: true)
            #expect(String(header.richSummary.characters) == "\u{1F41B} Fix the loader \u{1F389}")
            #expect(String(header.richDescription.characters) == "Found by \u{1F50D} https://example.com")
            #expect(header.richDescription.runs.compactMap(\.link) == [URL(string: "https://example.com")])
            #expect(LastCommitContent.make(repository)?.summary == "\u{1F41B} Fix the loader \u{1F389}")
            await fixture.settle()
        }
    }

    @Test("a branch's place: its history with its tip selected, then Compare to Branch's Behind, with a commit main doesn't have")
    func branchPlace() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            let branch = try #require(fixture.repository.gitState.branches.all.first { $0.name == "fix/crash" })
            let history = fixture.history
            await fixture.show(.branch(ref: branch.ref))
            #expect(history.mode == .history)
            #expect(history.shownBranch?.name == "fix/crash")
            #expect(history.selection.shas == [fixture.shas["Fix crash on empty repository"]!])

            HistoryPlaces.showComparison(of: branch, in: fixture.context)
            await fixture.show(.branch(ref: branch.ref))
            #expect(history.mode == .compare(branch, .behind))
            #expect(history.commitSHAs == [fixture.shas["Fix crash on empty repository"]!])

            // Back to its history.
            fixture.context.state.history.branchView = BranchViewChoice(ref: branch.ref, view: .history)
            await fixture.show(.branch(ref: branch.ref))
            #expect(history.mode == .history)
            await fixture.settle()
        }
    }

    @Test("another branch's place rewrites nothing, not even the current branch's commits it shows: menus, keyboard reorder, and drops; cherry-picking stays")
    func branchPlaceRewrites() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            let actions = fixture.context.actions
            let history = fixture.history
            let head = try #require(fixture.shas["Bump version"])
            let merge = try #require(fixture.shas["Merge branch 'feature/login'"])
            let docs = try #require(fixture.shas["Update docs"])
            let wire = try #require(fixture.shas["Wire device flow"])
            let feature = try #require(fixture.repository.gitState.branches.all.first { $0.name == "feature/login" })
            await fixture.show(.branch(ref: feature.ref))
            #expect(!history.showsCurrentBranchHistory)
            // The graph shows HEAD's commits; none of them rewrites here.
            let mergeRow = try #require(history.row(of: merge))
            #expect(!actions.canPerform(.reorder(shas: [head], before: nil)))
            #expect(!actions.canPerform(.squash(shas: [head], into: merge)))
            #expect(!actions.canPerform(.resetToCommit(sha: docs)))
            let content = CommitContextMenus.menuContent(shas: [head], clicked: try #require(history.commit(head)), repository: fixture.repository)
            #expect(!content.canAmend)
            #expect(!content.canUndo)
            history.select(shas: [head], contiguous: true)
            await actions.performAndWait(.reorder(shas: nil, before: nil))
            #expect(fixture.context.state.history.reorder == nil)
            let payload = CommitDragPayload(repositoryID: fixture.repository.id, shas: [head])
            #expect(CommitDragging.validate(payload, .above(row: mergeRow + 1), repository: fixture.repository, context: fixture.context) == nil)
            #expect(CommitDragging.validate(payload, .onto(row: mergeRow), repository: fixture.repository, context: fixture.context) == nil)
            // Its commits can be copied to the current branch.
            #expect(actions.canPerform(.cherryPick(shas: [wire], target: nil)))

            // In History, HEAD's commit moves again.
            await fixture.show(.history)
            #expect(history.showsCurrentBranchHistory)
            #expect(actions.canPerform(.reorder(shas: [head], before: nil)))
            #expect(actions.canPerform(.resetToCommit(sha: docs)))
            await fixture.settle()
        }
    }

    @Test("a tag off the simple list's line says so and offers the graph, which shows it")
    func tagOffTheLine() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            try await runGit(["tag", "crash-fix", "fix/crash"], fixture.local)
            await fixture.repository.refresh(.full, reason: .user)
            fixture.history.setStyle(.simple)
            await fixture.show(.tag(name: "crash-fix"))
            let notice = try #require(fixture.context.state.history.notice)
            #expect(notice.place == .tag(name: "crash-fix"))
            #expect(notice.kind == .notOnLine(branch: "main"))

            // Show in Graph: the graph has it, and selects it.
            fixture.history.setStyle(.graph)
            await fixture.show(.tag(name: "crash-fix"))
            #expect(fixture.context.state.history.notice == nil)
            #expect(fixture.history.selection.shas == [fixture.shas["Fix crash on empty repository"]!])
            await fixture.settle()
        }
    }

    @Test("Compare to Branch lists every branch but the current one and fork remotes', each with how far the current branch is behind and ahead")
    func compareToBranchList() async throws {
        try await withIsolatedGitConfig { _ in
            // `feature` has two commits `main` doesn't; `main` one it doesn't.
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "f1.txt", "f1\n", message: "F1")
                try await commitFile(local, "f2.txt", "f2\n", message: "F2")
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "m1.txt", "m1\n", message: "M1")
                try await runGit(["update-ref", "refs/remotes/espalier-octocat/feature", "feature"], local)
                try await runGit(["update-ref", "refs/remotes/github-desktop-hubot/feature", "feature"], local)
            }
            let repository = fixture.repository
            let state = repository.gitState
            let content = BranchPickerContent.make(
                branches: state.branches.all,
                defaultBranch: state.branches.defaultBranch,
                recentBranches: state.branches.recent,
                includesRemoteBranches: true,
                filter: "",
                candidates: repository.history.comparableBranches
            )
            #expect(state.branches.all.contains { $0.name == "espalier-octocat/feature" })
            #expect(!repository.history.comparableBranches.contains { $0.isDesktopForkRemoteBranch || $0.name == "main" })
            #expect(content.branches.map(\.name) == ["feature"])

            let comparison = try #require(BranchComparison.make(repository))
            let feature = try fixture.branch("feature")
            #expect(comparison.currentBranch == "main")
            #expect(comparison.cached(feature) == nil)
            let counted = await comparison.load(feature)
            #expect(counted == AheadBehind(ahead: 1, behind: 2))
            #expect(comparison.cached(feature) == counted)
            #expect(counted.map { BranchComparisonCounts($0, currentBranch: comparison.currentBranch).text } == "↓2 ↑1")

            // A detached HEAD has nothing to compare with.
            try await fixture.git(["checkout", "-q", "--detach", "HEAD"])
            await fixture.refresh()
            #expect(BranchComparison.make(repository) == nil)
        }
    }

    @Test("the Commit menu follows desktop's rules for each commit")
    func commitMenuRules() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            await fixture.show(.history)
            let actions = fixture.context.actions
            let head = fixture.shas["Bump version"]!
            let merge = fixture.shas["Merge branch 'feature/login'"]!
            let docs = fixture.shas["Update docs"]!
            // No upstream: every commit is local. Reset to a commit below
            // HEAD on its line; never to HEAD or another branch's commit.
            #expect(actions.canPerform(.resetToCommit(sha: merge)))
            #expect(actions.canPerform(.resetToCommit(sha: docs)))
            #expect(!actions.canPerform(.resetToCommit(sha: head)))
            #expect(!actions.canPerform(.resetToCommit(sha: fixture.shas["Fix crash on empty repository"]!)))
            // Checkout every commit but HEAD's.
            #expect(!actions.canPerform(.checkoutCommit(sha: head)))
            #expect(actions.canPerform(.checkoutCommit(sha: docs)))
            #expect(actions.canPerform(.revertCommit(sha: docs)))
            // Reorder: HEAD's commit can move; below the merge it can't, but
            // the item stays enabled to say why; another branch's commit
            // can't either, and has nothing to explain.
            #expect(actions.canPerform(.reorder(shas: [head], before: nil)))
            #expect(actions.canPerform(.reorder(shas: [docs], before: nil)))
            #expect(!actions.canPerform(.reorder(shas: [fixture.shas["Fix crash on empty repository"]!], before: nil)))
            // Only a tag created here and not pushed can be deleted.
            #expect(!actions.canPerform(.deleteTag(name: "v1.0")))
            #expect(actions.title(for: .reorder(shas: [head, merge], before: nil)) == "Reorder 2 Commits…")
            #expect(actions.title(for: .reorder(shas: [head], before: nil)) == "Reorder Commit")
            // Without a GitHub repository, nothing to view.
            #expect(!actions.canPerform(.viewCommitOnGitHub(sha: head)))

            // The commit's context menu offers Amend and Undo on HEAD.
            let content = CommitContextMenus.menuContent(rows: [1], clicked: try #require(fixture.history.commit(head)), repository: fixture.repository)
            #expect(content.canAmend)
            #expect(content.canUndo)
            let tagged = CommitContextMenus.menuContent(
                rows: [try #require(fixture.history.row(of: fixture.shas["Add loader"]!))],
                clicked: try #require(fixture.history.commit(fixture.shas["Add loader"]!)),
                repository: fixture.repository
            )
            #expect(tagged.tags == ["v1.0"])
            #expect(!tagged.canAmend && !tagged.canUndo)
            await fixture.settle()
        }
    }

    @Test("context menus: one commit's items in desktop's order, several commits', the working copy's")
    func contextMenus() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            await fixture.show(.history)
            let history = fixture.history
            @MainActor func titles(_ rows: [Int], clicked: Int) throws -> [String] {
                MenuRecorder.Popup.titles(CommitContextMenus.menu(rows: rows, clickedRow: clicked, repository: fixture.repository, context: fixture.context))
            }
            let tagged = try #require(history.row(of: fixture.shas["Add loader"]!))
            #expect(try titles([tagged], clicked: tagged) == [
                "Reset to Commit…", "Check Out Commit", "Reorder Commit", "Revert Changes in Commit", "—",
                "Create Branch from Commit…", "Create Tag…", "—", "Delete Tag v1.0…", "Cherry-pick Commit…", "—",
                "Copy SHA", "Copy Tag", "View on GitHub",
            ])
            let head = try #require(history.row(of: fixture.shas["Bump version"]!))
            #expect(try titles([head], clicked: head).prefix(2) == ["Amend Commit…", "Undo Commit…"])
            #expect(try titles([head, head + 1], clicked: head) == ["Cherry-pick 2 Commits…", "Squash 2 Commits…", "Reorder 2 Commits…"])
            #expect(try titles([0], clicked: 0) == ["Review Changes", "—", "Stash All Changes", "Discard All Changes…"])
            await fixture.settle()
        }
    }

    @Test("drops: squash and reorder on the current branch's line, never across a merge or onto themselves")
    func drops() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            await fixture.show(.history)
            let history = fixture.history
            let head = fixture.shas["Bump version"]!
            let merge = fixture.shas["Merge branch 'feature/login'"]!
            let payload = CommitDragPayload(repositoryID: fixture.repository.id, shas: [head])
            let mergeRow = try #require(history.row(of: merge))
            let headRow = try #require(history.row(of: head))

            // Below the merge: taken, to say why it can't be done (the merge
            // would be replayed); see `mergeReasons`.
            #expect(CommitDragging.validate(payload, .above(row: mergeRow + 2), repository: fixture.repository, context: fixture.context) == .insertAbove)
            // Right where it is: refused.
            #expect(CommitDragging.validate(payload, .above(row: headRow), repository: fixture.repository, context: fixture.context) == nil)
            // Onto itself: refused.
            #expect(CommitDragging.validate(payload, .onto(row: headRow), repository: fixture.repository, context: fixture.context) == nil)
            // From another repository: refused.
            let other = CommitDragPayload(repositoryID: RepositoryID(), shas: [head])
            #expect(CommitDragging.validate(other, .above(row: mergeRow + 1), repository: fixture.repository, context: fixture.context) == nil)
            // The payload carries the dragged commits.
            #expect(CommitDragging.payload([head], repository: fixture.repository, context: fixture.context)?.shas == [head])
            await fixture.settle()
        }
    }

    @Test("a squash or reorder a merge commit blocks says why: from the menus, keyboard reorder, and drops")
    func mergeReasons() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture(dirty: false)
            await fixture.show(.history)
            let history = fixture.history
            let actions = fixture.context.actions
            let presenter = fixture.context.presenter
            let head = try #require(fixture.shas["Bump version"])
            let docs = try #require(fixture.shas["Update docs"])
            let loader = try #require(fixture.shas["Add loader"])
            let signIn = try #require(fixture.shas["Add sign-in sheet"])
            let reorderReason = "Can't reorder. Reordering replays every commit back to the oldest one involved, and none of them can be a merge commit."
            let squashReason = "Can't squash. Squashing replays every commit back to the oldest one involved, and none of them can be a merge commit."
            let before = try await runGit(["rev-parse", "main"], fixture.local)

            @MainActor func takeReason() -> String? {
                guard let presented = presenter.error else {
                    return nil
                }
                presenter.dismissError(presented.id)
                if case .precondition(let message) = presented.error.reason {
                    return message
                }
                return nil
            }

            // Reorder Commit below the merge: no keyboard reorder, the reason.
            await actions.performAndWait(.reorder(shas: [docs], before: nil))
            #expect(fixture.context.state.history.reorder == nil)
            #expect(takeReason() == reorderReason)
            // A commit the merge brought in, too.
            #expect(actions.canPerform(.reorder(shas: [signIn], before: nil)))
            await actions.performAndWait(.reorder(shas: [signIn], before: nil))
            #expect(takeReason() == reorderReason)

            // Squash below the merge.
            #expect(actions.canPerform(.squash(shas: [docs], into: loader)))
            await actions.performAndWait(.squash(shas: [docs], into: loader))
            #expect(takeReason() == squashReason)
            // One commit alone still can't be squashed.
            #expect(!actions.canPerform(.squash(shas: [docs], into: nil)))

            // Keyboard reorder of HEAD's commit, confirmed below the merge.
            history.select(shas: [head], contiguous: true)
            await actions.performAndWait(.reorder(shas: nil, before: nil))
            let state = fixture.context.state.history
            #expect(state.reorder?.shas == [head])
            let mergeRow = try #require(history.row(of: fixture.shas["Merge branch 'feature/login'"]!))
            let docsRow = try #require(history.row(of: docs))
            state.reorder?.insertionRow = docsRow + 1
            await KeyboardReorder.confirm(repository: fixture.repository, context: fixture.context)
            #expect(state.reorder == nil)
            #expect(takeReason() == reorderReason)
            // Right where it is (below itself): nothing to do or say.
            history.select(shas: [head], contiguous: true)
            await actions.performAndWait(.reorder(shas: nil, before: nil))
            state.reorder?.insertionRow = (history.row(of: head) ?? 0) + 1
            await KeyboardReorder.confirm(repository: fixture.repository, context: fixture.context)
            #expect(state.reorder == nil)
            #expect(presenter.error == nil)
            #expect(mergeRow > (history.row(of: head) ?? 0))

            // A drop below the merge, and a drop onto a commit below it.
            let payload = CommitDragPayload(repositoryID: fixture.repository.id, shas: [head])
            #expect(CommitDragging.accept(payload, .above(row: docsRow + 1), repository: fixture.repository, context: fixture.context))
            #expect(takeReason() == reorderReason)
            #expect(CommitDragging.validate(payload, .onto(row: docsRow), repository: fixture.repository, context: fixture.context) != nil)
            #expect(CommitDragging.accept(payload, .onto(row: docsRow), repository: fixture.repository, context: fixture.context))
            await waitUntil { presenter.error != nil }
            #expect(takeReason() == squashReason)
            // Dropped back where it is: refused, without a reason.
            let below = CommitDragPayload(repositoryID: fixture.repository.id, shas: [docs])
            #expect(CommitDragging.validate(below, .above(row: docsRow), repository: fixture.repository, context: fixture.context) == nil)
            #expect(CommitDragging.validate(below, .above(row: docsRow + 1), repository: fixture.repository, context: fixture.context) == nil)

            await fixture.settle()
            #expect(try await runGit(["rev-parse", "main"], fixture.local) == before)
        }
    }

    @Test("keyboard reorder moves a commit where the line is")
    func keyboardReorder() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryFixtureForReorder()
            await fixture.show(.history)
            let history = fixture.history
            let state = fixture.context.state.history
            let c = try #require(fixture.shas["C"])
            history.select(shas: [c], contiguous: true)
            KeyboardReorder.begin(nil, repository: fixture.repository, context: fixture.context)
            let start = try #require(state.reorder)
            #expect(start.shas == [c])
            #expect(start.insertionRow == history.row(of: c))

            // Down below B: C goes before B, so the history reads D, B, C, A.
            KeyboardReorder.move(by: 2, repository: fixture.repository, state: state)
            #expect(state.reorder?.insertionRow == (history.row(of: c) ?? 0) + 2)
            await KeyboardReorder.confirm(repository: fixture.repository, context: fixture.context)
            #expect(state.reorder == nil)
            await fixture.settle()
            let log = try await runGit(["log", "--format=%s", "main"], fixture.local)
            #expect(log.split(separator: "\n") == ["D", "B", "C", "A"])
            await fixture.settle()
        }
    }

    /// `main`: A, B, C, D, all local.
    private func makeHistoryFixtureForReorder() async throws -> HistoryScreenFixture {
        let local = try setupEmptyRepository("main")
        var shas: [String: String] = [:]
        for name in ["A", "B", "C", "D"] {
            let path = POSIXPath.join(local.path, "\(name).txt")
            try Data("\(name)\n".utf8).write(to: URL(filePath: path))
            try await runGit(["add", "--", "\(name).txt"], local)
            try await runGit(["commit", "-q", "-m", name], local)
            shas[name] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        }
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        return HistoryScreenFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: shas)
    }
}
