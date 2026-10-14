// Shallow clones end to end through the models: `--depth 1` and
// `--shallow-since` clones of a local remote; History's last commit and
// graph, Commit Info, Compare, ahead/behind, fetch, pull, and push. Nothing
// unshallows a clone.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: shallow clones", .offline) @MainActor
struct ShallowCloneTests {
    /// A bare remote whose `main` has four commits, a year apart from 2020,
    /// each adding file<n>.txt.
    private func makeRemote() async throws -> Repository {
        let seed = Repository(path: try createTempDirectory())
        try await runGit(["init", "-q", "-b", "main"], seed)
        for index in 1...4 {
            try Data("\(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(seed.path, "file\(index).txt")))
            try await runGit(["add", "--", "file\(index).txt"], seed)
            let date = "\(2019 + index)-01-01T12:00:00Z"
            let result = try await Dugite.exec(
                ["commit", "-q", "-m", "Commit \(index)"],
                seed.path,
                options: Dugite.ExecutionOptions(env: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
            )
            #expect(result.exitCode == 0)
        }
        return try await makeBareRemote(from: seed)
    }

    /// A shallow clone of `remote` (through `file://`, as git ignores the
    /// depth of a plain local path).
    private func shallowClone(_ remote: Repository, _ options: [String]) async throws -> Repository {
        let directory = try createTempDirectory()
        let path = POSIXPath.join(directory, "clone")
        let result = try await Dugite.exec(["clone", "-q"] + options + ["--", "file://\(remote.path)", path], directory)
        #expect(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        return Repository(path: path)
    }

    private func makeFixture(_ local: Repository) async throws -> ChangesFixture {
        // History writes a commit-graph, as in the app (git skips it in a
        // shallow repository).
        let harness = try AppHarness(writesCommitGraphs: true)
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = ChangesFixture(harness: harness, app: app, model: model, local: local)
        await fixture.settle()
        return fixture
    }

    @Test("a --depth 1 clone: History ends at its one commit, with no parent, and Commit Info lists its files")
    func depthOneHistory() async throws {
        let remote = try await makeRemote()
        let local = try await shallowClone(remote, ["--depth", "1"])
        let fixture = try await makeFixture(local)
        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(fixture.gitState.tip.branch?.upstream == "origin/main")
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(fixture.gitState.localCommitSHAs.isEmpty)

        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["Commit 4"])
        #expect(fixture.history.isComplete)
        #expect(fixture.history.loadError == nil)
        let tip = try #require(fixture.history.commitSHAs.first)
        #expect(fixture.history.commit(tip)?.parentSHAs.isEmpty == true)
        #expect(fixture.history.parentRow(ofRow: try #require(fixture.history.row(of: tip))) == nil)

        // Commit Info: the boundary commit shows every file it has.
        fixture.history.select(shas: [tip], contiguous: true)
        await fixture.settleHistory()
        #expect(fixture.history.selection.changeset.value?.files.map(\.path) == ["file1.txt", "file2.txt", "file3.txt", "file4.txt"])
        #expect(fixture.history.selection.changeset.failure == nil)
    }

    @Test("a --depth 1 clone commits, pushes, fetches, and pulls, with ahead/behind along the way")
    func depthOneSync() async throws {
        let remote = try await makeRemote()
        let local = try await shallowClone(remote, ["--depth", "1"])
        let fixture = try await makeFixture(local)

        // Commit and push.
        try fixture.write("mine.txt", "mine\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        let mine = try await fixture.commitIncluded("Mine")
        await fixture.refresh(.full)
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(fixture.commit.undoableCommitSHA == mine.sha)
        _ = try await fixture.model.sync.push()
        await fixture.settle()
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(JSCompat.trim(try await runGit(["rev-parse", "refs/heads/main"], remote)) == mine.sha)

        // Someone else pushes; fetch, then pull.
        try await pushCommitFromAnotherClone(remote, path: "theirs.txt", contents: "theirs\n", message: "Theirs")
        try await fixture.model.sync.fetch()
        await fixture.settle()
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 1))
        #expect(try await fixture.model.sync.pull() == .completed)
        await fixture.settle()
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(fixture.exists("theirs.txt"))

        // Still shallow: History ends at the clone's commit.
        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["Theirs", "Mine", "Commit 4"])
        #expect(try await fixture.git(["rev-parse", "--is-shallow-repository"]) == "true\n")
    }

    @Test("a --shallow-since clone: History ends at the first commit since, and Compare works above the boundary")
    func shallowSince() async throws {
        let remote = try await makeRemote()
        let local = try await shallowClone(remote, ["--shallow-since=2021-06-01"])
        let fixture = try await makeFixture(local)

        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["Commit 4", "Commit 3"])
        let boundary = try #require(fixture.history.commitSHAs.last)
        #expect(fixture.history.commit(boundary)?.parentSHAs.isEmpty == true)

        // A branch from the boundary, compared with main.
        let feature = try await fixture.model.branches.createBranch("feature", startPoint: boundary)
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "feature")
        try fixture.write("feature.txt", "feature\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        _ = try await fixture.commitIncluded("Feature")
        await fixture.refresh(.full)
        #expect(feature.name == "feature")

        try await fixture.history.compare(with: try fixture.branch("main"), direction: .behind)
        await fixture.settleHistory()
        #expect(fixture.history.comparison.aheadBehind == AheadBehind(ahead: 1, behind: 1))
        #expect(fixture.historySummaries == ["Commit 4"])
        #expect(fixture.history.comparison.mergePreview?.status != nil)
    }
}
