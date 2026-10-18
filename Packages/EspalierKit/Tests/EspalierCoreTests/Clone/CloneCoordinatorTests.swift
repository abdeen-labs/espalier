// The clone flow against local repositories: progress, cancelling while
// git fetches and while it checks out, failures and Retry Clone, Clone
// Again, the selection, Git LFS, forks, and quitting. Held clones go
// through a scripted ssh or a checkout hook; nothing touches the network.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Clone coordinator", .offline, .hangGuard(minutes: 5)) @MainActor
struct CloneCoordinatorTests {
    // MARK: Cloning

    @Test("shows the clone while git runs, then adds and selects the repository")
    func clonesAndAdds() async throws {
        let source = try await makeCloneSource()
        let ssh = try SSHCloneGate()
        let harness = try AppHarness(git: gitRuntime(adding: ssh.environment))
        let app = await harness.loadedApp()
        let destination = try cloneDestination("hello")

        let cloning = Task { try await app.clones.clone(CloneRequest(url: "  \(ssh.url(source.path))\n", path: destination)) }
        let held = try await ssh.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }

        let task = try #require(app.clones.clones.first)
        #expect(app.clones.clones.count == 1)
        #expect(task.url == ssh.url(source.path))
        #expect(task.path == destination)
        #expect(task.phase == .cloning)
        // Git's progress: none yet, but maybe its first line.
        #expect(task.progress?.value == 0)
        #expect(app.clones.task(task.id) == task)
        #expect(app.selection == .clone(task.id))
        #expect(app.repositoryListGroups.flatMap(\.items).contains { $0.id == .clone(task.id) })
        // The dialog remembers the folder for the next clone.
        #expect(app.preferences.lastCloneLocation == POSIXPath.dirname(destination))
        #expect(app.clones.defaultClonePath(for: "octocat/other") == POSIXPath.join(POSIXPath.dirname(destination), "other"))

        #expect(ssh.gate.release())
        let result = try await cloning.value

        #expect(app.clones.clones.isEmpty)
        #expect(app.selection == .repository(result.repositoryID))
        let record = try #require(app.record(result.repositoryID))
        #expect(record.path == destination)
        #expect(!record.isMissing)
        #expect(!result.usesLFS)
        #expect(!result.isFork)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, "README.md")))
        await app.idle()
        #expect(app.repository(result.repositoryID)?.gitState.tip.branch?.name == "master")
        #expect(app.repository(result.repositoryID)?.gitState.remotes.defaultRemote?.url == ssh.url(source.path))
    }

    @Test("the clone's progress follows git's")
    func progress() async throws {
        let source = try await makeCloneSource()
        let hook = try CheckoutHookGate()
        // Over ssh git reports what it receives (a local clone reports
        // nothing).
        let ssh = try passThroughSSH()
        let harness = try AppHarness(git: gitRuntime(adding: hook.environment.merging(ssh.environment) { $1 }))
        let app = await harness.loadedApp()
        let destination = try cloneDestination()

        let cloning = Task { try await app.clones.clone(ssh.url(source.path), to: destination) }
        let held = try await hook.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }

        // Git has fetched and checked out: the progress is git's.
        await waitForState { (app.clones.clones.first?.progress?.value ?? 0) > 0 }
        let progress = try #require(app.clones.clones.first?.progress)
        #expect(progress.value <= 1)
        #expect(progress.description != nil)

        #expect(hook.gate.release())
        let id = try await cloning.value
        #expect(app.record(id)?.path == destination)
        await app.idle()
    }

    @Test("a clone the user moved away from doesn't take the selection when it's done")
    func selectionStaysWhereTheUserWent() async throws {
        let source = try await makeCloneSource()
        let ssh = try SSHCloneGate()
        let harness = try AppHarness(git: gitRuntime(adding: ssh.environment))
        let app = await harness.loadedApp()
        let other = try await harness.addAndSelect(try await setupTwoCommitRepo(), to: app)

        let cloning = Task { try await app.clones.clone(ssh.url(source.path), to: try cloneDestination()) }
        let held = try await ssh.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }
        let task = try #require(app.clones.clones.first)
        #expect(app.selection == .clone(task.id))

        // Adding a repository doesn't move the selection off the clone.
        _ = try await app.addRepositories([try await setupTwoCommitRepo().path])
        #expect(app.selection == .clone(task.id))

        app.select(.repository(other.id))
        #expect(ssh.gate.release())
        let id = try await cloning.value
        #expect(app.selection == .repository(other.id))
        #expect(app.record(id) != nil)
        #expect(app.clones.clones.isEmpty)
        await app.idle()
    }

    @Test("a folder with files, or one being cloned into, is refused before anything starts")
    func refusesDestinations() async throws {
        let source = try await makeCloneSource()
        let ssh = try SSHCloneGate()
        let harness = try AppHarness(git: gitRuntime(adding: ssh.environment))
        let app = await harness.loadedApp()
        let defaultLocation = app.preferences.lastCloneLocation

        let full = try createTempDirectory()
        try Data("x".utf8).write(to: URL(filePath: POSIXPath.join(full, "file")))
        let error = await #expect(throws: OperationError.self) {
            try await app.clones.clone(source.path, to: full)
        }
        #expect(preconditionText(error) != nil)
        #expect(error?.operation == .clone)
        #expect(app.clones.clones.isEmpty)
        #expect(app.selection == nil)
        #expect(app.preferences.lastCloneLocation == defaultLocation)

        let emptyError = await #expect(throws: OperationError.self) {
            try await app.clones.clone(source.path, to: "")
        }
        #expect(preconditionText(emptyError) != nil)

        // A relative path would mean one folder to git and another to the
        // cleanup of a cancelled clone.
        let relativeError = await #expect(throws: OperationError.self) {
            try await app.clones.clone(source.path, to: "Developer/hello")
        }
        #expect(preconditionText(relativeError) != nil)
        #expect(app.clones.clones.isEmpty)

        // Two clones into one folder would write into the same repository.
        let destination = try cloneDestination()
        let cloning = Task { try await app.clones.clone(ssh.url(source.path), to: destination) }
        let held = try await ssh.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }
        let duplicate = await #expect(throws: OperationError.self) {
            try await app.clones.clone(source.path, to: destination + "/")
        }
        #expect(preconditionText(duplicate) != nil)
        #expect(app.clones.clones.count == 1)

        #expect(ssh.gate.release())
        _ = try await cloning.value
        await app.idle()
    }

    // MARK: Cancelling

    @Test("cancelling while git fetches stops it, leaves no folder, and selects what was selected")
    func cancelWhileFetching() async throws {
        let source = try await makeCloneSource()
        let ssh = try SSHCloneGate()
        let harness = try AppHarness(git: gitRuntime(adding: ssh.environment))
        let app = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try await setupTwoCommitRepo(), to: app)
        let destination = try cloneDestination()

        let cloning = Task { try await app.clones.clone(ssh.url(source.path), to: destination) }
        let held = try await ssh.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }
        let task = try #require(app.clones.clones.first)

        app.clones.cancel(task.id)
        #expect(app.clones.task(task.id)?.phase == .cancelling)
        #expect(app.clones.task(task.id)?.canCancel == false)
        let error = await #expect(throws: OperationError.self) {
            try await cloning.value
        }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(error?.isCancellation == true)
        #expect(app.clones.clones.isEmpty)
        #expect(app.selection == .repository(selected.id))
        #expect(!FileManager.default.fileExists(atPath: destination))
        // The ssh script git started ends too.
        #expect(await ssh.gate.waitUntilGone(held))
        #expect(!ssh.gate.release())
        #expect(app.repositories.count == 1)
        await app.idle()
    }

    @Test("cancelling once git is checking out removes the repository git keeps")
    func cancelWhileCheckingOut() async throws {
        let source = try await makeCloneSource()
        let hook = try CheckoutHookGate()
        let harness = try AppHarness(git: gitRuntime(adding: hook.environment))
        let app = await harness.loadedApp()
        let destination = try cloneDestination()

        let cloning = Task { try await app.clones.clone(source.path, to: destination) }
        let held = try await hook.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, "README.md")))

        app.clones.remove(try #require(app.clones.clones.first).id)
        let error = await #expect(throws: OperationError.self) {
            try await cloning.value
        }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(!FileManager.default.fileExists(atPath: destination))
        #expect(await hook.gate.waitUntilGone(held))
        #expect(app.repositories.isEmpty)
        #expect(app.selection == nil)
        await app.idle()
    }

    @Test("cancelling a clone into an empty folder that was there empties it again")
    func cancelKeepsExistingFolder() async throws {
        let source = try await makeCloneSource()
        let hook = try CheckoutHookGate()
        let harness = try AppHarness(git: gitRuntime(adding: hook.environment))
        let app = await harness.loadedApp()
        let destination = try createTempDirectory()

        let cloning = Task { try await app.clones.clone(source.path, to: destination) }
        let held = try await hook.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }

        app.clones.cancel(try #require(app.clones.clones.first).id)
        await #expect(throws: OperationError.self) {
            try await cloning.value
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        await app.idle()
    }

    @Test("quitting cancels the clones")
    func quittingCancels() async throws {
        let source = try await makeCloneSource()
        let ssh = try SSHCloneGate()
        let harness = try AppHarness(git: gitRuntime(adding: ssh.environment))
        let app = await harness.loadedApp()
        let destination = try cloneDestination()

        let cloning = Task { try await app.clones.clone(ssh.url(source.path), to: destination) }
        let held = try await ssh.gate.waitUntilHeld(while: cloning)
        defer { Darwin.close(held) }

        await app.prepareForTermination()
        #expect(app.clones.clones.isEmpty)
        #expect(app.clones.isIdle)
        #expect(!FileManager.default.fileExists(atPath: destination))
        let error = await #expect(throws: OperationError.self) {
            try await cloning.value
        }
        #expect(error?.isCancellation == true)
    }

    // MARK: Failing and retrying

    @Test("a failed clone offers Retry Clone, which clones it again")
    func failureAndRetry() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try await setupTwoCommitRepo(), to: app)
        let sourcePath = POSIXPath.join(try createTempDirectory(), "later")
        let destination = try cloneDestination()

        let error = try #require(await #expect(throws: OperationError.self) {
            try await app.clones.clone(sourcePath, to: destination)
        })
        #expect(error.operation == .clone)
        #expect(error.recoveries.map(\.kind) == [.retry(.clone)])
        let retry = try #require(error.retry as? CloneRetry)
        #expect(retry.request == CloneRequest(url: sourcePath, path: destination))
        #expect(retry.missingRepositoryID == nil)
        #expect(app.clones.clones.isEmpty)
        #expect(app.selection == .repository(selected.id))

        // The repository appears; retrying clones it.
        try FileManager.default.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        let source = Repository(path: sourcePath)
        try await runGit(["init", "-b", "main"], source)
        try await makeCommit(source, Tree(entries: [TreeEntry(path: "file.txt", contents: "later\n")]))
        try await error.recoveries[0].perform(in: app)

        let added = try #require(app.repositories.first { $0.path == destination })
        #expect(app.selection == .repository(added.id))
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, "file.txt")))
        await app.idle()
    }

    // MARK: Clone Again

    @Test("Clone Again clones a missing repository into its folder and finds it again")
    func cloneAgain() async throws {
        let upstream = try await makeCloneSource()
        let cloneURL = "https://github.com/octocat/hello.git"
        // Git fetches the GitHub URL from the local repository.
        let harness = try AppHarness(git: gitRuntime(adding: [
            "GIT_CONFIG_PARAMETERS": "'url.\(upstream.path).insteadOf=\(cloneURL)'",
        ]))
        let app = await harness.loadedApp()
        let local = try await cloneRepository(upstream)
        let model = try await harness.addAndSelect(local, to: app)
        let gitHubRepository = app.upsertGitHubRepository(dotComEndpoint, apiFullRepository(owner: "octocat", name: "hello"))
        app.setGitHubRepository(gitHubRepository, for: model.id)
        #expect(app.record(model.id)?.gitHubRepository?.cloneURL == cloneURL)
        model.commit.draft.summary = "Kept"

        try FileManager.default.removeItem(atPath: local.path)
        await app.checkRepositoryAgain(model.id)
        #expect(model.record.isMissing)

        try await app.clones.cloneAgain(model.id)

        #expect(!model.record.isMissing)
        #expect(model.record.path == local.path)
        #expect(app.selection == .repository(model.id))
        #expect(app.clones.clones.isEmpty)
        #expect(app.repositories.count == 1)
        #expect(model.commit.draft.summary == "Kept")
        await app.idle()
        #expect(model.availability == .available)
        #expect(model.gitState.tip.branch?.name == "master")
    }

    @Test("Clone Again needs a clone URL, and its failure retries Clone Again")
    func cloneAgainFailures() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let local = try await setupTwoCommitRepo()
        let model = try await harness.addAndSelect(local, to: app)

        let noURL = await #expect(throws: OperationError.self) {
            try await app.clones.cloneAgain(model.id)
        }
        #expect(preconditionText(noURL) != nil)

        // A clone URL nothing answers at.
        let unreachable = POSIXPath.join(try createTempDirectory(), "gone")
        let gitHubRepository = app.upsertGitHubRepository(
            dotComEndpoint,
            APIFullRepository(
                repository: createMockAPIRepository(cloneURL: unreachable, name: "gone", owner: createMockAPIIdentity(login: "octocat")),
                parent: nil,
                permissions: nil
            )
        )
        app.setGitHubRepository(gitHubRepository, for: model.id)
        try FileManager.default.removeItem(atPath: local.path)
        await app.checkRepositoryAgain(model.id)

        let failure = try #require(await #expect(throws: OperationError.self) {
            try await app.clones.cloneAgain(model.id)
        })
        #expect(failure.repositoryID == model.id)
        #expect((failure.retry as? CloneRetry)?.missingRepositoryID == model.id)
        #expect(failure.recoveries.map(\.kind) == [.retry(.clone)])
        #expect(model.record.isMissing)
        #expect(app.selection == .repository(model.id))
        await app.idle()
    }

    // MARK: What to ask after cloning

    @Test("a cloned repository that uses Git LFS asks to initialize it")
    func clonedLFS() async throws {
        let source = try await makeCloneSource([
            ".gitattributes": "*.psd filter=lfs diff=lfs merge=lfs -text\n",
            "README.md": "hello\n",
        ])
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        let result = try await app.clones.clone(CloneRequest(url: source.path, path: try cloneDestination()))
        #expect(result.usesLFS)
        #expect(app.lfsInitializationPrompt(for: [result.repositoryID]) != nil)
        await app.idle()
    }

    @Test("a cloned fork asks how it will be used")
    func clonedFork() async throws {
        let upstream = try await makeCloneSource()
        let harness = try AppHarness(git: gitRuntime(adding: try sshServing(upstream)))
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(
            owner: "octocat",
            name: "hello",
            parent: apiRepository(owner: "upstream", name: "hello", ownerID: 2)
        )))
        let app = await harness.loadedAppWithAccounts()

        let result = try await app.clones.clone(CloneRequest(url: "git@github.com:octocat/hello.git", path: try cloneDestination()))
        #expect(result.isFork)
        #expect(app.record(result.repositoryID)?.gitHubRepository?.parent?.owner.login == "upstream")
        await settle(app, harness)
    }
}
