// The author dates of branch tips that branch lists show
// (BranchTipDates.swift).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Branch tip dates", .offline) @MainActor
struct BranchTipDatesTests {
    @Test("dates each branch's tip once, from its author date, and caches them")
    func dates() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
            try await runGit(["commit", "--amend", "--no-edit", "--date=2021-03-04T05:06:07Z"], local)
            // A second branch on the same commit: one lookup.
            try await runGit(["branch", "feature-copy"], local)
            try await runGit(["checkout", "main"], local)
        }
        let feature = try selected.branch("feature")
        let copy = try selected.branch("feature-copy")
        let main = try selected.branch("main")
        #expect(selected.model.branches.cachedTipDate(feature.tip.sha) == nil)

        let dates = await selected.model.branches.tipDates(for: [feature, copy, main])
        #expect(dates.count == 2)
        #expect(dates[feature.tip.sha] == Date(timeIntervalSince1970: 1_614_834_367))
        #expect(dates[main.tip.sha] != nil)
        #expect(selected.model.branches.tipDateCache.count == 2)
        #expect(selected.model.branches.cachedTipDate(feature.tip.sha) == dates[feature.tip.sha])

        // Cached: the same answer without git.
        #expect(await selected.model.branches.tipDates(for: [copy]) == [copy.tip.sha: dates[feature.tip.sha]!])
        await selected.app.idle()
    }

    @Test("a failure returns the cached dates and caches nothing")
    func failure() async throws {
        let selected = try await makeSelectedRepository { _ in }
        let main = try selected.branch("main")
        _ = await selected.model.branches.tipDates(for: [main])

        let missing = Branch(
            name: "gone",
            upstream: nil,
            tip: BranchTip(sha: String(repeating: "1", count: 40)),
            type: .local,
            ref: "refs/heads/gone"
        )
        let dates = await selected.model.branches.tipDates(for: [main, missing])
        #expect(dates.keys.sorted() == [main.tip.sha])
        #expect(selected.model.branches.tipDateCache.count == 1)
        await selected.app.idle()
    }
}
