// What the Rename Worktree sheet relies on. A new name is a folder's name
// only ("a/b" would move the worktree into another folder), and git's
// refusal to move a worktree whose submodules are initialized (the
// worktrees Espalier adds get theirs) is said plainly, with git's error
// kept underneath.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Renaming worktrees", .offline) @MainActor
struct WorktreeRenameTests {
    @Test("a name with \"/\" is refused, and the worktree stays where it is")
    func slash() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()

        let error = try #require(await #expect(throws: OperationError.self) {
            try await fixture.model.worktrees.rename(linked, to: "elsewhere/feature-tree")
        })
        #expect(error.reason == .precondition("Worktree names can't contain “/”."))
        #expect(error.reason == .precondition(WorktreesModel.slashInNameMessage))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.directory, "elsewhere")))
        await fixture.app.idle()
        #expect(fixture.model.worktrees.entries.map(\.path).contains(linked.path))
    }

    @Test("a worktree with submodules: git's refusal is said plainly, and nothing moves")
    func submodules() async throws {
        let submodule = try await setupTwoCommitRepo()
        let parent = try await setupTwoCommitRepo()
        try await runGit(["-c", "protocol.file.allow=always", "submodule", "add", "--", submodule.path, "lib"], parent)
        try await runGit(["commit", "-m", "Add lib"], parent)
        try await runGit(["branch", "other"], parent)
        let harness = try AppHarness(git: gitRuntime(adding: ["GIT_CONFIG_PARAMETERS": "'protocol.file.allow=always'"]))
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let path = POSIXPath.join(try createTempDirectory(), "other-tree")
        let entry = try await model.worktrees.add(AddWorktreeRequest(path: path, branchName: "other"))
        await app.idle()

        let error = try #require(await #expect(throws: OperationError.self) {
            try await model.worktrees.rename(entry, to: "renamed")
        })
        #expect(error.reason == .precondition("Git can't move or rename a worktree that contains submodules."))
        #expect(error.operation == .moveWorktree)
        #expect(error.gitFailure?.message.contains("working trees containing submodules cannot be moved or removed") == true)
        #expect(error.title == "Error")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(model.record.path == path)
        await app.idle()
    }
}
