// Another branch's place shows that branch's history: in the simple style its
// first-parent line from its tip, with its own unpushed marks and where it
// started, but not the base's notice (Update merges into the current branch).
// Nothing rewrites there, not even the current branch's commits on its line.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Another branch's history", .offline) @MainActor
struct BranchHistoryTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    /// `main` (Main 1 and Main 2 pushed, Main 3 not) checked out;
    /// `feature` from Main 2 with Feature 1 and Feature 2, unpublished;
    /// `ahead` from Main 3 with Ahead 1, unpublished.
    private func makeRepository() async throws -> Repository {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(5)), ("Main 2", at(4))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(3), "Feature 1", in: local)
        try await commitAt(at(2), "Feature 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(1), "Main 3", in: local)
        try await runGit(["checkout", "-q", "-b", "ahead"], local)
        try await commitAt(at(0), "Ahead 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        return local
    }

    @Test("the simple style lists another branch's first-parent line with its own unpushed marks and start, without the base's notice")
    func simpleLine() async throws {
        let local = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.simpleLines == ["Main 3 (unpushed)", "Main 2", "Main 1"])

        history.showBranch(ref: try fixture.branch("feature").ref)
        await fixture.settle()
        #expect(history.shownBranch?.name == "feature")
        #expect(fixture.simpleLines == ["Feature 2 (unpushed)", "Feature 1 (unpushed)", "Main 2", "Main 1"])
        #expect(history.selection.shas == [try await fixture.sha("feature")])
        // main has Main 3, which feature doesn't, but Update would merge it
        // into the current branch.
        #expect(history.simpleBaseStatus == nil)
        #expect(history.simpleStart?.base.name == "main")
        #expect(history.simpleStart?.row == 2)

        history.showBranch(ref: nil)
        await fixture.settle()
        #expect(history.shownBranch == nil)
        #expect(fixture.simpleLines == ["Main 3 (unpushed)", "Main 2", "Main 1"])
        #expect(history.selection.shas == [try await fixture.sha("main")])
    }

    @Test("the current branch's own place shows HEAD's line")
    func currentBranchPlace() async throws {
        let local = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        history.showBranch(ref: try fixture.branch("main").ref)
        await fixture.settle()
        #expect(history.shownBranch == nil)
        #expect(history.showsCurrentBranchHistory)
        #expect(fixture.simpleLines == ["Main 3 (unpushed)", "Main 2", "Main 1"])
    }

    @Test("another branch's history rewrites nothing, not even the current branch's commits on its line, in either style")
    func noRewrites() async throws {
        let local = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let main3 = try await fixture.sha("main")
        let main2 = try await fixture.sha("main~1")
        #expect(history.showsCurrentBranchHistory)
        #expect(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: nil) != .unavailable)
        #expect(history.currentBranchRewrite(moving: [main3], relativeTo: main2) != nil)

        // `ahead`'s line has main's commits under its own.
        history.showBranch(ref: try fixture.branch("ahead").ref)
        await fixture.settle()
        #expect(fixture.summaries == ["Ahead 1", "Main 3", "Main 2", "Main 1"])
        #expect(!history.showsCurrentBranchHistory)
        #expect(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: nil) == .unavailable)
        #expect(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: main2) == .unavailable)
        #expect(history.currentBranchRewrite(moving: [main3], relativeTo: main2) == nil)

        // The graph shows the scope, and still rewrites nothing.
        history.setStyle(.graph)
        await fixture.settle()
        #expect(history.row(of: main3) != nil)
        #expect(!history.showsCurrentBranchHistory)
        #expect(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: main2) == .unavailable)

        history.showBranch(ref: nil)
        await fixture.settle()
        #expect(history.showsCurrentBranchHistory)
        #expect(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: main2) != .unavailable)
    }
}
