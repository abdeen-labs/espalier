// What merging a branch would do, for the merge sheet's status line, and
// when the merge can start (MergePreview.swift).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Merge preview", .offline) @MainActor
struct MergePreviewTests {
    @Test("a clean merge counts the commits it brings in")
    func clean() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "one.txt", "one\n")
            try await commitFile(local, "two.txt", "two\n")
            try await runGit(["checkout", "main"], local)
        }
        let preview = try #require(await selected.model.operations.mergePreview(of: try selected.branch("feature")))
        #expect(preview == MergePreview(status: .clean, commitCount: 2))
        #expect(preview.canStart)
        await selected.app.idle()
    }

    @Test("an up-to-date branch brings in nothing, so there's nothing to start")
    func upToDate() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["branch", "feature"], local)
            try await commitFile(local, "main.txt", "main\n")
        }
        let preview = try #require(await selected.model.operations.mergePreview(of: try selected.branch("feature")))
        #expect(preview == MergePreview(status: .clean, commitCount: 0))
        #expect(!preview.canStart)
        await selected.app.idle()
    }

    @Test("conflicts are counted by file, and the merge can start")
    func conflicts() async throws {
        let selected = try await makeSelectedRepository { local in
            try await commitFile(local, "shared.txt", numberedLines)
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "shared.txt", numberedLinesReplacing(3, with: "feature"))
            try await runGit(["checkout", "main"], local)
            try await commitFile(local, "shared.txt", numberedLinesReplacing(3, with: "main"))
        }
        let preview = try #require(await selected.model.operations.mergePreview(of: try selected.branch("feature")))
        #expect(preview == MergePreview(status: .conflicts(conflictedFiles: 1), commitCount: 1))
        #expect(preview.canStart)
        await selected.app.idle()
    }

    @Test("unrelated histories can't be merged")
    func unrelated() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["checkout", "--orphan", "other"], local)
            try await runGit(["rm", "-rf", "--quiet", "."], local)
            try await commitFile(local, "other.txt", "other\n")
            try await runGit(["checkout", "main"], local)
        }
        let preview = try #require(await selected.model.operations.mergePreview(of: try selected.branch("other")))
        #expect(preview == MergePreview(status: .invalid, commitCount: 0))
        #expect(!preview.canStart)
        await selected.app.idle()
    }

    @Test("a merge git can't check is unknown, not clean, and can still start")
    func checkFails() async throws {
        let selected = try await makeSelectedRepository { local in
            try await makeBranchMergeTreeCantRead(local)
        }
        let preview = try #require(await selected.model.operations.mergePreview(of: try selected.branch("feature")))
        #expect(preview == MergePreview(status: nil, commitCount: 1))
        #expect(preview.canStart)
        await selected.app.idle()
    }

    @Test("commits git can't count are unknown, not none, and the merge can still start")
    func countFails() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "one.txt", "one\n")
            try await runGit(["checkout", "main"], local)
        }
        // The branch is renamed after the sheet listed it: its tip still
        // merges, its name no longer counts.
        let feature = try selected.branch("feature")
        try await runGit(["branch", "-m", "feature", "renamed"], selected.local)
        let preview = try #require(await selected.model.operations.mergePreview(of: feature))
        #expect(preview == MergePreview(status: .clean, commitCount: nil))
        #expect(preview.canStart)
        await selected.app.idle()
    }

    @Test("without a current branch there's no preview")
    func detached() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["branch", "feature"], local)
            try await runGit(["checkout", "--detach"], local)
        }
        #expect(await selected.model.operations.mergePreview(of: try selected.branch("feature")) == nil)
        await selected.app.idle()
    }

    /// `feature` changes a line of a file `main` changes elsewhere, so
    /// merging needs both versions, and the feature's version is deleted
    /// from the object database: `git merge-tree` fails, while the commits
    /// can still be counted.
    private func makeBranchMergeTreeCantRead(_ local: Repository) async throws {
        try await commitFile(local, "shared.txt", numberedLines)
        try await runGit(["checkout", "-b", "feature"], local)
        try await commitFile(local, "shared.txt", numberedLinesReplacing(2, with: "feature"))
        try await runGit(["checkout", "main"], local)
        try await commitFile(local, "shared.txt", numberedLinesReplacing(7, with: "main"))
        let blob = JSCompat.trim(try await runGit(["rev-parse", "feature:shared.txt"], local))
        let object = POSIXPath.join(local.path, ".git", "objects", String(blob.prefix(2)), String(blob.dropFirst(2)))
        try FileManager.default.removeItem(atPath: object)
    }
}
