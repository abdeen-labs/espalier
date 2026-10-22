// Go ▸ Back, Forward, First Parent, Second Parent, and Child in the simple
// list, where going to a commit selects it (the list scrolls to it itself),
// and Back and Forward kept per repository.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History navigation", .offline, .hangGuard(minutes: 5)) @MainActor
struct HistoryNavigationTests {
    /// `main` with README (the root), A, B, and C, in the simple list, and
    /// the commits' SHAs by summary.
    private func linearFixture() async throws -> (OperationsFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeOperationsFixture { local in
            for name in ["A", "B", "C"] {
                shas[name] = try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
            }
        }
        shas["README"] = try await fixture.sha("main~3")
        fixture.repository.history.setStyle(.simple)
        await fixture.loadHistory()
        return (fixture, shas)
    }

    @Test("in the simple list, First Parent and Child select the commit, and Back and Forward return to the commits gone from")
    func parentsAndChildren() async throws {
        let (fixture, shas) = try await linearFixture()
        let history = fixture.repository.history
        let navigator = fixture.context.state.history.navigator
        let a = try #require(shas["A"]), b = try #require(shas["B"]), c = try #require(shas["C"])

        history.select(shas: [c], contiguous: true)
        navigator.goToParent(index: 0, in: history)
        #expect(history.selection.shas == [b])
        navigator.goToParent(index: 0, in: history)
        #expect(history.selection.shas == [a])

        #expect(navigator.canGoBack(in: history))
        navigator.goBack(in: history)
        #expect(history.selection.shas == [b])
        #expect(navigator.canGoForward(in: history))
        navigator.goForward(in: history)
        #expect(history.selection.shas == [a])

        navigator.goToChild(in: history)
        #expect(history.selection.shas == [b])
    }

    @Test("in the simple list, Second Parent selects the commit inside the merge, and Back returns to the merge")
    func secondParentInsideMerge() async throws {
        var shas: [String: String] = [:]
        let fixture = try await makeOperationsFixture { local in
            try await runGit(["checkout", "-q", "-b", "side"], local)
            shas["S"] = try await commitFile(local, "S.txt", "S\n", message: "S")
            try await runGit(["checkout", "-q", "main"], local)
            shas["A"] = try await commitFile(local, "A.txt", "A\n", message: "A")
            try await runGit(["merge", "-q", "--no-ff", "-m", "M", "side"], local)
        }
        let m = try await fixture.sha("main")
        let s = try #require(shas["S"])
        let history = fixture.repository.history
        history.setStyle(.simple)
        await fixture.loadHistory()
        let navigator = fixture.context.state.history.navigator

        history.select(shas: [m], contiguous: true)
        #expect(history.row(of: s) == nil)
        #expect(navigator.canGoToParent(index: 1, in: history))
        navigator.goToParent(index: 1, in: history)
        await waitUntil { navigator.pendingSHA == nil }
        #expect(history.selection.shas == [s])

        navigator.goBack(in: history)
        #expect(history.selection.shas == [m])
    }

    @Test("Back and Forward are kept per repository: another repository has none, and leaves the first one's alone")
    func perRepository() async throws {
        let (fixture, shas) = try await linearFixture()
        let history = fixture.repository.history
        let navigator = fixture.context.state.history.navigator
        let b = try #require(shas["B"]), c = try #require(shas["C"])

        history.select(shas: [c], contiguous: true)
        navigator.goToParent(index: 0, in: history)
        #expect(history.selection.shas == [b])
        #expect(navigator.canGoBack(in: history))

        let other = try await fixture.harness.addAndSelect(try setupEmptyRepository(), to: fixture.app)
        #expect(!navigator.canGoBack(in: other.history))
        navigator.goBack(in: other.history)

        fixture.app.select(.repository(fixture.repository.id))
        await fixture.settle()
        #expect(navigator.canGoBack(in: history))
        navigator.goBack(in: history)
        await waitUntil { navigator.pendingSHA == nil }
        #expect(history.selection.shas == [c])
    }
}
