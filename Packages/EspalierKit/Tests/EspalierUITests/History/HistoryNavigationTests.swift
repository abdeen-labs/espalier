// Following the graph: Back and Forward, stubs' tooltips, following a stub
// to its other end and back, parents and children across stubs, and
// VoiceOver's description of a row.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History navigation", .offline) @MainActor
struct HistoryNavigationTests {
    // MARK: Back and Forward

    @Test("Back and Forward return through the commits jumped between")
    func stack() {
        var stack = HistoryNavigationStack()
        #expect(stack.goBack(from: "x") == nil)
        stack.record(from: "a")
        stack.record(from: "b")
        // At c: back to b, then a; forward to b, then c.
        #expect(stack.goBack(from: "c") == "b")
        #expect(stack.goBack(from: "b") == "a")
        #expect(stack.goBack(from: "a") == nil)
        #expect(stack.goForward(from: "a") == "b")
        #expect(stack.goForward(from: "b") == "c")
        #expect(stack.goForward(from: "c") == nil)
        // A new jump forgets what was ahead.
        _ = stack.goBack(from: "c")
        stack.record(from: "b")
        #expect(stack.forward.isEmpty)
        // The same place twice in a row is remembered once.
        stack.record(from: "b")
        #expect(stack.back.filter { $0 == "b" }.count == 1)
    }

    // MARK: Tooltips

    @Test("a stub's tooltip says how far it continues and to which commit")
    func tooltips() throws {
        let commits = graphCommits("""
            M m4 f2
            f2 f1
            f1 B
            m4 m3
            m3 m2
            m2 m1
            m1 B
            B A
            A
            """)
        let history = SyntheticHistory(commits, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3))
        history.publishFirstPage(9)
        let f1 = 2, b = 7
        let outgoing = try #require(history.graph[f1].edges.first { $0.kind == .outgoingStub })
        let incoming = try #require(history.graph[b].edges.first { $0.kind == .incomingStub })
        #expect(StubNavigator.tooltip(for: outgoing, row: f1, source: history, isLoading: false) == "Continues 5 commits below: B Commit B")
        #expect(StubNavigator.tooltip(for: incoming, row: b, source: history, isLoading: false) == "Comes from 5 commits above: f1 Commit f1")

        // Not loaded yet, then loading; not in the history once complete.
        let partial = SyntheticHistory(commits, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3))
        partial.publishFirstPage(6)
        let unloaded = try #require(partial.graph[f1].edges.first { $0.kind == .outgoingStub })
        #expect(unloaded.parentRow == nil)
        #expect(StubNavigator.tooltip(for: unloaded, row: f1, source: partial, isLoading: false) == "Continues below the loaded commits (B). Click to load them.")
        #expect(StubNavigator.tooltip(for: unloaded, row: f1, source: partial, isLoading: true) == "Continues below the loaded commits (B). Loading…")
        let missing = SyntheticHistory(Array(commits.prefix(6)), options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3))
        missing.publishFirstPage(6)
        let gone = try #require(missing.graph[f1].edges.first { $0.kind == .outgoingStub })
        #expect(StubNavigator.tooltip(for: gone, row: f1, source: missing, isLoading: false) == "This commit's parent isn't in the history shown.")
    }

    // MARK: Following stubs on a real repository

    /// `main`: 40 commits, then a merge of `feature`, whose one commit forks
    /// from the first: in topological order its line is longer than a
    /// screen, so it's drawn as stubs.
    private func makeLongBranch() async throws -> (HistoryScreenFixture, GraphTableHarnessForModel) {
        let local = try setupEmptyRepository("main")
        var shas: [String: String] = [:]
        shas["c1"] = try await datedGit(local, date: "1700000000 +0000", writing: "file.txt", ["commit", "-q", "-m", "c1"])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        shas["f1"] = try await datedGit(local, date: "1700000060 +0000", writing: "feature.txt", ["commit", "-q", "-m", "f1"])
        try await runGit(["checkout", "-q", "main"], local)
        for number in 2...40 {
            try await runGit(["commit", "-q", "--allow-empty", "-m", "c\(number)"], local)
        }
        shas["c40"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        try await runGit(["merge", "-q", "--no-ff", "-m", "M", "feature"], local)
        shas["M"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        let fixture = HistoryScreenFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: shas)
        await fixture.show(.history)
        return (fixture, GraphTableHarnessForModel(fixture: fixture))
    }

    @Test("following a stub selects its other end and records the jump; Back returns")
    func followStub() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, table) = try await makeLongBranch()
            let history = fixture.history
            let navigator = fixture.context.state.history.navigator
            let f1Row = try #require(history.row(of: fixture.shas["f1"]!))
            let stub = try #require(history.graph[f1Row].edges.first { $0.kind == .outgoingStub })
            let c1Row = try #require(stub.parentRow)
            #expect(history.commit(atRow: c1Row)?.sha == fixture.shas["c1"])

            history.select(shas: [fixture.shas["f1"]!], contiguous: true)
            table.update()
            navigator.follow(row: f1Row, edge: stub, in: history)
            #expect(history.selection.shas == [fixture.shas["c1"]!])
            #expect(navigator.canGoBack)

            // And back up the incoming stub's other end.
            let incoming = try #require(history.graph[c1Row].edges.first { $0.kind == .incomingStub })
            #expect(incoming.childRow == f1Row)

            table.update()
            navigator.goBack(in: history)
            #expect(history.selection.shas == [fixture.shas["f1"]!])
            #expect(navigator.canGoForward)
            table.update()
            navigator.goForward(in: history)
            #expect(history.selection.shas == [fixture.shas["c1"]!])
            // Following the incoming stub goes back up to f1.
            table.update()
            navigator.follow(row: c1Row, edge: incoming, in: history)
            #expect(history.selection.shas == [fixture.shas["f1"]!])
            await fixture.settle()
        }
    }

    @Test("parents and children are followed across stubs")
    func parentsAndChildren() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, table) = try await makeLongBranch()
            let history = fixture.history
            let navigator = fixture.context.state.history.navigator
            // From the merge: its second parent is f1.
            history.select(shas: [fixture.shas["M"]!], contiguous: true)
            table.update()
            #expect(navigator.canGoToParent(index: 1, in: history))
            navigator.goToParent(index: 1, in: history)
            #expect(history.selection.shas == [fixture.shas["f1"]!])
            // f1's first parent, c1, is far below: across the stub.
            table.update()
            navigator.goToParent(index: 0, in: history)
            #expect(history.selection.shas == [fixture.shas["c1"]!])
            // c1 has two children whose first parent it is, f1 (topmost,
            // across the stub) and c2: Go to Child stays on c1's own line.
            table.update()
            #expect(navigator.canGoToChild(in: history))
            navigator.goToChild(in: history)
            let c2 = try #require(history.selection.shas.first)
            #expect(history.commit(c2)?.summary == "c2")
            // f1's only child is the merge, on another line.
            history.select(shas: [fixture.shas["f1"]!], contiguous: true)
            table.update()
            navigator.goToChild(in: history)
            #expect(history.selection.shas == [fixture.shas["M"]!])
            await fixture.settle()
        }
    }

    // MARK: VoiceOver

    @Test("VoiceOver hears a row's commit and what its drawing shows")
    func accessibility() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, table) = try await makeLongBranch()
            let history = fixture.history
            let presentation = GraphPresentation(repository: fixture.repository, place: .history)
            let mergeRow = try #require(history.row(of: fixture.shas["M"]!))
            let merge = GraphAccessibility.value(forRow: mergeRow, source: history, presentation: presentation)
            #expect(merge.hasPrefix("HEAD. Merge commit with 2 parents. Branch tip: main."))
            // Without a remote nothing is unpushed; with one, the local
            // commits are.
            #expect(!merge.contains("Not pushed."))
            try await runGit(["remote", "add", "origin", try createTempDirectory()], fixture.local)
            await fixture.repository.refresh(reason: .user)
            await fixture.settle()
            let withRemote = GraphPresentation(repository: fixture.repository, place: .history)
            #expect(GraphAccessibility.value(forRow: mergeRow, source: history, presentation: withRemote).contains("Not pushed."))
            let f1Row = try #require(history.row(of: fixture.shas["f1"]!))
            #expect(GraphAccessibility.value(forRow: f1Row, source: history, presentation: presentation).contains("First parent is 40 commits below."))
            #expect(GraphAccessibility.value(forRow: 0, source: history, presentation: presentation) == "No uncommitted changes.")
            // The scroll status counts the loaded rows.
            table.update()
            #expect(GraphAccessibility.scrollStatus(table.controller)?.hasPrefix("Commits 1 to ") == true)
            #expect(GraphAccessibility.rotors(for: table.controller).map(\.label) == ["Branch Tips", "Tags", "Merge Commits", "Unpushed Commits"])
            await fixture.settle()
        }
    }
}

/// The graph table on a real history, in an offscreen window, with
/// History's actions, so jumps select rows as the app does.
@MainActor
final class GraphTableHarnessForModel {
    let controller = GraphTableController()
    let window: SnapshotWindow
    let fixture: HistoryScreenFixture

    init(fixture: HistoryScreenFixture) {
        self.fixture = fixture
        window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = SnapshotAppearance.light.appearance
        controller.fixedNow = UIFixtures.now
        controller.avatarLoader = MonogramAvatarLoader()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        controller.scrollView.frame = container.bounds
        container.addSubview(controller.scrollView)
        window.contentView = container
        fixture.context.state.history.controller = controller
        update()
    }

    /// Applies the model's state to the table, as SwiftUI does.
    func update() {
        let history = fixture.history
        controller.actions = HistoryTableActions.make(repository: fixture.repository, context: fixture.context)
        controller.update(
            source: history,
            presentation: GraphPresentation(repository: fixture.repository, place: .history),
            selection: GraphSelection(shas: history.selection.shas, isWorkingCopy: history.isWorkingCopySelected),
            reorderInsertionRow: nil
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
