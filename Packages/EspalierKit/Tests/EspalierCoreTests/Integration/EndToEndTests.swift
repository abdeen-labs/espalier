// An end-to-end run of the app model alone, as the UI drives it, against
// real git and a local bare remote: staging, committing, branching,
// merging, pushing, and a relaunch. A merge's conflicts are
// MergeOperationTests' "finishing commits the merge with the chosen side,
// kept across refreshes, and clears the message"; a rejected push and its
// recovery, PushOperationTests'; a commit through the real hooks proxy
// (Abort, then Ignore), CommitOperationTests' "Abort in a failing hook's
// prompt cancels the commit; Ignore lets it land".

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("End to end", .offline) @MainActor
struct EndToEndTests {
    @Test("stages, commits, branches, merges, and pushes to a local bare remote, and the list survives a relaunch")
    func gate() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, remote) = try await setupRepositoryWithRemote()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            let id = repository.id
            #expect(repository.gitState.tip.branch?.name == "main")
            #expect(repository.changes.workingDirectory.files.isEmpty)

            // Stage: the watcher sees two new files; include only one.
            try harness.write("greeting.txt", "hello\n", in: local)
            try harness.write("notes.txt", "notes\n", in: local)
            harness.fileWatcher.emit(batch: [local.path + "/greeting.txt", local.path + "/notes.txt"])
            await harness.scheduler.waitForSleepers(1)
            await harness.scheduler.advance(by: .milliseconds(300))
            await repository.idle()
            #expect(repository.changes.workingDirectory.files.map(\.path) == ["greeting.txt", "notes.txt"])
            let greeting = try #require(repository.changes.workingDirectory.files.first { $0.path == "greeting.txt" })
            repository.changes.setIncludeAll(false)
            repository.changes.setIncluded([greeting.id], true)

            // Commit.
            repository.commit.draft.summary = "Add greeting"
            let first = try await repository.commit.commit()
            #expect(!first.amended)
            #expect(repository.gitState.tip.branch?.tip.sha == first.sha)
            #expect(repository.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
            #expect(repository.commit.draft.summary.isEmpty)

            // Branch. With changes, the user decides where they go; bring them
            // along, as the UI does after showing the decision.
            let decision = await #expect(throws: OperationError.self) {
                try await repository.branches.createBranch("feature", startPoint: nil)
            }
            #expect(decision?.reason == .decisionRequired(.uncommittedChanges(
                currentBranch: "main",
                targetBranch: "feature"
            )))
            await repository.idle()
            let created = try #require(repository.gitState.branches.all.first { $0.name == "feature" })
            #expect(try await repository.branches.checkout(created, strategy: .moveToNewBranch) == .checkedOut(created))
            #expect(repository.gitState.tip.branch?.name == "feature")
            #expect(repository.changes.workingDirectory.files.map(\.path) == ["notes.txt"])

            // Commit on it.
            try harness.write("feature.txt", "feature\n", in: local)
            await repository.refresh(.status, reason: .user)
            let featureFile = try #require(repository.changes.workingDirectory.files.first { $0.path == "feature.txt" })
            repository.changes.setIncludeAll(false)
            repository.changes.setIncluded([featureFile.id], true)
            repository.commit.draft.summary = "Add feature"
            let featureCommit = try await repository.commit.commit()

            // Back to main, bringing the untracked notes along, and merge.
            let main = try #require(repository.gitState.branches.all.first { $0.name == "main" })
            #expect(try await repository.branches.checkout(main, strategy: .moveToNewBranch) == .checkedOut(main))
            #expect(repository.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
            let feature = try #require(repository.gitState.branches.all.first { $0.name == "feature" })
            #expect(feature.tip.sha == featureCommit.sha)
            #expect(try await repository.operations.merge(feature) == .merged(ours: "main", theirs: "feature"))
            await repository.idle()
            let log = try await runGit(["log", "--format=%s", "main"], local)
            #expect(log.split(separator: "\n").contains("Add feature"))
            #expect(repository.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 0))

            // Push to the bare remote.
            let pushed = try await repository.sync.push()
            #expect(pushed == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))
            await repository.idle()
            let remoteTip = try await runGit(["rev-parse", "refs/heads/main"], remote)
            #expect(JSCompat.trim(remoteTip) == repository.gitState.tip.branch?.tip.sha)
            #expect(repository.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
            #expect(harness.prompts.history.isEmpty)

            // The list, the repository's ID, and the selection survive a
            // relaunch.
            await app.idle()
            let relaunched = await harness.loadedApp()
            #expect(relaunched.repositories.map(\.id) == [id])
            #expect(relaunched.selection == .repository(id))
            await relaunched.idle()
        }
    }
}
