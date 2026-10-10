// Ported from desktop/app/test/unit/ahead-behind-store-test.ts
//
// The comparison is an async call that a cancelled task abandons
// (`BranchesModel`'s `aheadBehind(from:to:)`).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("AheadBehindStore", .offline) @MainActor
struct AheadBehindCacheTests {
    /// A repository with `master` and `feature`, added to an app. `diverge`
    /// adds a commit to `master` after branching.
    private func makeRepository(diverge: Bool) async throws -> (AppHarness, AppModel, RepositoryModel, mainSHA: String, featureSHA: String) {
        let repo = try setupEmptyRepository()

        // Create initial commit on master
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "base.txt", contents: "base")], commitMessage: "initial commit"))

        // Create a feature branch and add a commit
        try await createBranch(repo, "feature", "HEAD")
        try await switchTo(repo, "feature")
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "feature.txt", contents: "feature work")], commitMessage: "feature commit"))
        let featureSHA = try await sha(repo)

        // Go back to master and add a different commit
        try await switchTo(repo, "master")
        if diverge {
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "main.txt", contents: "main work")], commitMessage: "main commit"))
        }
        let mainSHA = try await sha(repo)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repo, to: app)
        return (harness, app, model, mainSHA, featureSHA)
    }

    private func sha(_ repository: Repository) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
    }

    @Suite("getAheadBehind", .offline)
    @MainActor
    struct GetAheadBehind {
        let tests = AheadBehindCacheTests()

        @Test("calculates ahead/behind for diverged branches")
        func diverged() async throws {
            let (_, app, model, mainSHA, featureSHA) = try await tests.makeRepository(diverge: true)

            // Now get the ahead/behind count
            let result = await model.branches.aheadBehind(from: mainSHA, to: featureSHA)

            // master is 1 ahead (its own commit) and 1 behind (the feature commit)
            #expect(result == AheadBehind(ahead: 1, behind: 1))
            await app.idle()
        }

        @Test("supports aborting via disposable")
        func aborting() async throws {
            let (_, app, model, mainSHA, featureSHA) = try await tests.makeRepository(diverge: false)

            let aborted = Task { await model.branches.aheadBehind(from: mainSHA, to: featureSHA) }
            // Immediately cancel — the caller gets nothing.
            aborted.cancel()
            #expect(await aborted.value == nil)

            // Confirm the comparison still works for the next caller.
            #expect(await model.branches.aheadBehind(from: mainSHA, to: featureSHA) == AheadBehind(ahead: 0, behind: 1))
            await app.idle()
        }
    }
}
