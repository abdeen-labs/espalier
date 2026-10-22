// Where drag and keyboard reorder put commits, in the graph (its
// uncommitted-work row on top, the commits from row 1) and in the simple
// list (the commits from row 0): the commit an insertion line moves them
// below, where they already are, where the keyboard's line starts and
// stops, and a move or squash that would replay a merge commit.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Commit reorder", .offline, .hangGuard(minutes: 5)) @MainActor
struct CommitReorderTests {
    /// A history style, and the row of its first commit.
    typealias Style = (style: HistoryStyle, firstRow: Int)

    nonisolated static let styles: [NamedCase<Style>] = [
        NamedCase("in the graph, below the uncommitted-work row", (style: .graph, firstRow: 1)),
        NamedCase("in the simple list", (style: .simple, firstRow: 0)),
    ]

    /// `main` with README (the root), A, B, and C, its history shown in
    /// `style`, and the commits' SHAs by summary.
    private func linearFixture(_ style: HistoryStyle) async throws -> (OperationsFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeOperationsFixture { local in
            for name in ["A", "B", "C"] {
                shas[name] = try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
            }
        }
        shas["README"] = try await fixture.sha("main~3")
        fixture.repository.history.setStyle(style)
        await fixture.loadHistory()
        return (fixture, shas)
    }

    /// `main` with README (the root), A, M (merging `side`'s S, from
    /// README), and B, its history shown in `style`, and the commits' SHAs
    /// by summary.
    private func mergeFixture(_ style: HistoryStyle) async throws -> (OperationsFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeOperationsFixture { local in
            try await runGit(["checkout", "-q", "-b", "side"], local)
            shas["S"] = try await commitFile(local, "S.txt", "S\n", message: "S")
            try await runGit(["checkout", "-q", "main"], local)
            shas["A"] = try await commitFile(local, "A.txt", "A\n", message: "A")
            try await runGit(["merge", "-q", "--no-ff", "-m", "M", "side"], local)
            shas["B"] = try await commitFile(local, "B.txt", "B\n", message: "B")
        }
        shas["M"] = try await fixture.sha("main~1")
        fixture.repository.history.setStyle(style)
        await fixture.loadHistory()
        return (fixture, shas)
    }

    @Test("an insertion line moves commits below the commit in the row above it, or to the top above the first commit", arguments: styles)
    func reorderPlanBase(_ testCase: NamedCase<Style>) async throws {
        let (style, first) = testCase.value
        let (fixture, shas) = try await linearFixture(style)
        let history = fixture.repository.history
        let a = try #require(shas["A"]), b = try #require(shas["B"]), c = try #require(shas["C"]), readme = try #require(shas["README"])
        let rows = [c, b, a, readme].map { history.row(of: $0) }
        let expectedRows: [Int?] = [first, first + 1, first + 2, first + 3]
        #expect(rows == expectedRows)
        #expect(history.graph.count == first + 4)

        // Above C: the top.
        let top = try #require(CommitDragging.reorderPlan([c], aboveRow: first, history: history))
        #expect(top.base == nil)
        #expect(top.check.rewrite != nil)
        // Above A: below B.
        let middle = try #require(CommitDragging.reorderPlan([c], aboveRow: first + 2, history: history))
        #expect(middle.base?.sha == b)
        #expect(middle.check.rewrite != nil)
        // Below the last row: below README.
        let bottom = try #require(CommitDragging.reorderPlan([c], aboveRow: first + 4, history: history))
        #expect(bottom.base?.sha == readme)
        #expect(bottom.check.rewrite != nil)
        // Above the uncommitted-work row or the list, and past the last row:
        // no line.
        #expect(CommitDragging.reorderPlan([c], aboveRow: first - 1, history: history) == nil)
        #expect(CommitDragging.reorderPlan([c], aboveRow: first + 5, history: history) == nil)
    }

    @Test("adjacent commits are in place at the lines above, between, and below their rows; commits apart are in place nowhere", arguments: styles)
    func inPlace(_ testCase: NamedCase<Style>) async throws {
        let (style, first) = testCase.value
        let (fixture, shas) = try await linearFixture(style)
        let history = fixture.repository.history
        let a = try #require(shas["A"]), b = try #require(shas["B"]), c = try #require(shas["C"])
        let lines = Array(first...(first + 4))

        // B and A, in rows first + 1 and first + 2, oldest first.
        let adjacent = lines.map { CommitDragging.isInPlace([a, b], aboveRow: $0, history: history) }
        #expect(adjacent == [false, true, true, true, false])
        // C and A, with B between them.
        let apart = lines.map { CommitDragging.isInPlace([c, a], aboveRow: $0, history: history) }
        #expect(apart == [false, false, false, false, false])
    }

    @Test("keyboard reorder starts with the commits in row order and the line above the first of them", arguments: styles)
    func begin(_ testCase: NamedCase<Style>) async throws {
        let (style, first) = testCase.value
        let (fixture, shas) = try await linearFixture(style)
        let b = try #require(shas["B"]), readme = try #require(shas["README"])

        KeyboardReorder.begin([readme, b], repository: fixture.repository, context: fixture.context)
        #expect(fixture.context.state.history.reorder == KeyboardReorderState(shas: [b, readme], insertionRow: first + 1))
    }

    @Test("the keyboard's insertion line moves a line at a time, and stops above the first commit and below the last row", arguments: styles)
    func move(_ testCase: NamedCase<Style>) async throws {
        let (style, first) = testCase.value
        let (fixture, shas) = try await linearFixture(style)
        let c = try #require(shas["C"])
        let last = first + 4

        let rows = CommitRows(fixture.repository.history.graph)
        #expect(rows.insertionRow(first, movedBy: -1) == first)
        #expect(rows.insertionRow(last, movedBy: -10) == first)
        #expect(rows.insertionRow(last, movedBy: 1) == last)
        #expect(rows.insertionRow(first, movedBy: 10) == last)
        #expect(rows.insertionRow(first, movedBy: 2) == first + 2)

        let state = fixture.context.state.history
        KeyboardReorder.begin([c], repository: fixture.repository, context: fixture.context)
        KeyboardReorder.move(by: 1, repository: fixture.repository, state: state)
        #expect(state.reorder?.insertionRow == first + 1)
        KeyboardReorder.move(by: -1, repository: fixture.repository, state: state)
        #expect(state.reorder?.insertionRow == first)
    }

    @Test("a drop that would replay a merge commit is refused before it lands; keyboard reorder says why", arguments: styles)
    func mergeCommitReplayed(_ testCase: NamedCase<Style>) async throws {
        let (fixture, shas) = try await mergeFixture(testCase.value.style)
        let repository = fixture.repository, context = fixture.context
        let history = repository.history
        let b = try #require(shas["B"]), m = try #require(shas["M"]), readme = try #require(shas["README"])

        // B below README, the last row, or squashed into README: both
        // replay M, so neither drop is offered or taken.
        let moveB = CommitDragPayload(repositoryID: repository.id, shas: [b])
        let bottom = GraphDropTarget.above(row: history.graph.count)
        #expect(CommitDragging.validate(moveB, bottom, repository: repository, context: context) == nil)
        #expect(!CommitDragging.accept(moveB, bottom, repository: repository, context: context))
        let readmeRow = try #require(history.row(of: readme))
        #expect(CommitDragging.validate(moveB, .onto(row: readmeRow), repository: repository, context: context) == nil)
        #expect(!CommitDragging.accept(moveB, .onto(row: readmeRow), repository: repository, context: context))
        #expect(fixture.presenter.error == nil)

        // Keyboard reorder to the same line ends with the reason.
        let state = context.state.history
        KeyboardReorder.begin([b], repository: repository, context: context)
        state.reorder?.insertionRow = history.graph.count
        await KeyboardReorder.confirm(repository: repository, context: context)
        #expect(state.reorder == nil)
        let presented = try #require(fixture.presenter.error)
        #expect(presented.error.operation == .reorder)
        if case .precondition = presented.error.reason {} else {
            Issue.record("Unexpected error \(presented.error.reason)")
        }
        await fixture.settle()
        #expect(try await fixture.sha("main") == b)

        // M at the lines above and below its row, where it is.
        let moveM = CommitDragPayload(repositoryID: repository.id, shas: [m])
        let mergeRow = try #require(history.row(of: m))
        for row in [mergeRow, mergeRow + 1] {
            #expect(CommitDragging.validate(moveM, .above(row: row), repository: repository, context: context) == nil)
        }
    }
}
