// Ported from desktop/app/test/unit/git/pull/pull-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

private func setupRepositoryWithSubmodule() async throws -> (parent: Repository, submodule: Repository) {
    let parent = try setupEmptyRepository()
    let submodule = try setupEmptyRepository()

    // Add commits to submodule
    try await makeCommit(submodule, Tree(
        entries: [TreeEntry(path: "submodule-file.txt", contents: "hello from submodule")],
        commitMessage: "Initial commit in submodule"
    ))

    try await makeCommit(submodule, Tree(
        entries: [TreeEntry(path: "submodule-file.txt", contents: "updated content")],
        commitMessage: "Second commit in submodule"
    ))

    // Add commits to parent
    try await makeCommit(parent, Tree(
        entries: [TreeEntry(path: "README.md", contents: "# Parent repo")],
        commitMessage: "Initial commit in parent"
    ))

    // Add submodule to parent
    _ = try await Dugite.exec(
        [
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            submodule.path,
            "test-submodule",
        ],
        parent.path
    )

    _ = try await Dugite.exec(["commit", "-m", "Add submodule"], parent.path)

    return (parent, submodule)
}

private func commitCount(_ path: String) async throws -> Int {
    let log = try await Dugite.exec(["log", "--oneline"], path)
    return JSCompat.split(JSCompat.trim(String(decoding: log.stdout, as: UTF8.self)), "\n").count
}

@Suite("git/pull")
struct PullTests {
    @Suite("with submodules")
    struct WithSubmodules {
        @Test("updates submodule references after pulling changes")
        func updatesSubmodules() async throws {
            // Setup: Create parent with submodule, clone it
            let (parent, submodule) = try await setupRepositoryWithSubmodule()

            let cloned = try await cloneRepository(parent)

            // Initialize submodules in the cloned repo
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
                cloned.path
            )

            let submodulePath = POSIXPath.join(cloned.path, "test-submodule")

            // Verify initial state
            #expect(try await commitCount(submodulePath) == 2, "Should start with 2 commits")

            // Add a new commit to the submodule
            try await makeCommit(submodule, Tree(
                entries: [TreeEntry(path: "another-file.txt", contents: "more content")],
                commitMessage: "Third commit in submodule"
            ))

            // Update the submodule reference in parent and commit
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "update", "--remote"],
                parent.path
            )
            _ = try await Dugite.exec(["add", "test-submodule"], parent.path)
            _ = try await Dugite.exec(["commit", "-m", "Update submodule reference"], parent.path)

            let remote = Remote(name: "origin", url: parent.path)

            // Pull the changes
            try await pull(cloned, remote)

            // Verify submodule was updated to the new reference
            #expect(
                try await commitCount(submodulePath) == 3,
                "Submodule should now have 3 commits after update"
            )
        }

        @Test("handles pull when there are no submodule changes")
        func noSubmoduleChanges() async throws {
            let (parent, _) = try await setupRepositoryWithSubmodule()
            let cloned = try await cloneRepository(parent)

            // Initialize submodules
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
                cloned.path
            )

            // Make a change that doesn't affect submodules
            try await makeCommit(parent, Tree(
                entries: [TreeEntry(path: "README.md", contents: "# Another update")],
                commitMessage: "Update README again"
            ))

            let remote = Remote(name: "origin", url: parent.path)

            let submodulePath = POSIXPath.join(cloned.path, "test-submodule")
            let beforeCount = try await commitCount(submodulePath)

            // Pull should succeed without errors
            try await pull(cloned, remote)

            // Submodule should remain unchanged
            #expect(
                try await commitCount(submodulePath) == beforeCount,
                "Submodule commits should remain unchanged"
            )
            // The parent's change arrived.
            let readme = try String(contentsOfFile: POSIXPath.join(cloned.path, "README.md"), encoding: .utf8)
            #expect(readme == "# Another update")
        }
    }

    // MARK: - Espalier

    @Test("reports progress and passes terminal output on")
    func progressAndTerminalOutput() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let cloned = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))

        let progress = Mutex<[PullProgress]>([])
        let subscribed = Atomic(false)
        let options = PullOptions(
            progressCallback: { event in progress.withLock { $0.append(event) } },
            // The callback reaches git().
            onTerminalOutputAvailable: { _ in subscribed.store(true, ordering: .relaxed) }
        )

        try await pull(cloned, Remote(name: "origin", url: upstream.path), options)

        let events = progress.withLock { $0 }
        #expect(events.first == PullProgress(value: 0, title: "Pulling origin", remote: "origin"))
        #expect(events.allSatisfy { $0.title == "Pulling origin" && $0.remote == "origin" })
        let didSubscribe = subscribed.load(ordering: .relaxed)
        #expect(didSubscribe)
        let readme = try String(contentsOfFile: POSIXPath.join(cloned.path, "README.md"), encoding: .utf8)
        #expect(readme == "two")
    }

    @Test("a pull with rebase reads its conflicts as a rebase's even with GIT_ADVICE=0")
    func rebaseConflictsWithoutAdvice() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let cloned = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))
        try await makeCommit(cloned, Tree(entries: [TreeEntry(path: "README.md", contents: "three")]))
        _ = try await Dugite.exec(["config", "pull.rebase", "true"], cloned.path)

        // GIT_ADVICE=0 turns off the hint dugite recognizes rebase conflicts
        // by, whatever advice.mergeConflict says.
        try await withGitEnvironment(["GIT_ADVICE": "0"]) {
            let error = await #expect(throws: GitError.self) {
                try await pull(cloned, Remote(name: "origin", url: upstream.path))
            }
            #expect(error?.result.gitError == .rebaseConflicts)
        }
        let rebaseMerge = POSIXPath.join(cloned.path, ".git", "rebase-merge")
        #expect(FileManager.default.fileExists(atPath: rebaseMerge))
    }

    @Test("a pull with rebase refuses staged changes, as RebaseWithStagedChanges")
    func rebaseWithStagedChanges() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let cloned = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))
        _ = try await Dugite.exec(["config", "pull.rebase", "true"], cloned.path)
        try Data("staged".utf8).write(to: URL(filePath: POSIXPath.join(cloned.path, "notes.txt")))
        _ = try await Dugite.exec(["add", "notes.txt"], cloned.path)

        let error = await #expect(throws: GitError.self) {
            try await pull(cloned, Remote(name: "origin", url: upstream.path))
        }
        #expect(error?.result.gitError == .rebaseWithStagedChanges)
        #expect(error?.message == "Can't pull with rebase while you have uncommitted changes. Commit or stash them first.")
        let readme = try String(contentsOfFile: POSIXPath.join(cloned.path, "README.md"), encoding: .utf8)
        #expect(readme == "one")
    }

    @Test("a pull with rebase refuses to start over a rebase's leftover state, as RebaseAlreadyInProgress")
    func rebaseAlreadyInProgress() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let cloned = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))
        // Diverged: a pull that can fast-forward merges without rebasing.
        try await makeCommit(cloned, Tree(entries: [TreeEntry(path: "local.txt", contents: "local")]))
        _ = try await Dugite.exec(["config", "pull.rebase", "true"], cloned.path)
        try FileManager.default.createDirectory(
            atPath: POSIXPath.join(cloned.path, ".git", "rebase-merge"),
            withIntermediateDirectories: false
        )

        let error = await #expect(throws: GitError.self) {
            try await pull(cloned, Remote(name: "origin", url: upstream.path))
        }
        #expect(error?.result.gitError == .rebaseAlreadyInProgress)
        #expect(error?.message == "A rebase is already in progress. Finish or abort it first.")
        let readme = try String(contentsOfFile: POSIXPath.join(cloned.path, "README.md"), encoding: .utf8)
        #expect(readme == "one")
    }

    @Test("runs hooks unless told not to")
    func noVerify() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let cloned = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "a", contents: "a")]))
        _ = try await Dugite.exec(["config", "pull.rebase", "false"], cloned.path)
        _ = try await Dugite.exec(["config", "pull.ff", "false"], cloned.path)

        // A merge commit runs the commit-msg hook, which fails here.
        let hook = POSIXPath.join(cloned.path, ".git", "hooks", "commit-msg")
        try FileManager.default.createDirectory(
            atPath: POSIXPath.dirname(hook),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        let remote = Remote(name: "origin", url: upstream.path)
        await #expect(throws: GitError.self) {
            try await pull(cloned, remote)
        }
        _ = try await Dugite.exec(["merge", "--abort"], cloned.path)

        try await pull(cloned, remote, PullOptions(noVerify: true))
        #expect(try await getTipOrError(cloned).parentSHAs.count == 2)
    }
}
