// `RepositoryModel.perform`: the activity lifecycle, progress and hooks,
// refreshes after success and failure, background failures, busy
// policies, and shielding git from the caller's cancellation.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// An error a body throws.
private struct BodyFailure: Error {}

/// A git error as `git()` throws it.
private func gitError(_ stderr: String, exitCode: Int = 128) -> GitError {
    let dugiteError = Dugite.parseError(stderr)
    return GitError(
        result: GitResult(
            stdoutData: Data(),
            stderrData: Data(stderr.utf8),
            exitCode: exitCode,
            gitError: dugiteError,
            gitErrorDescription: dugiteError.flatMap { getDescriptionForError($0, stderr) },
            path: "/"
        ),
        args: ["status"],
        terminalOutput: stderr
    )
}

@Suite("Operation runner", .offline) @MainActor
struct OperationRunnerTests {
    /// A selected repository with a remote, refreshed.
    private func makeRepository(
        responder: PromptCenter.Responder? = PromptResponder.failing()
    ) async throws -> (AppHarness, AppModel, RepositoryModel) {
        let (local, _) = try await setupRepositoryWithRemote()
        let harness = try AppHarness(responder: responder)
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        return (harness, app, repository)
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    @Test("publishes the activity while the body runs, then clears it")
    func activityLifecycle() async throws {
        let (_, app, repository) = try await makeRepository()
        let during = try await repository.perform(OperationDescriptor(kind: .discardChanges)) { _ in
            (repository.localOperation?.kind, repository.networkOperation?.kind, app.runningMutations.map(\.operation.kind))
        }
        #expect(during.0 == .discardChanges)
        #expect(during.1 == nil)
        #expect(during.2 == [.discardChanges])
        #expect(repository.localOperation == nil)
        #expect(app.runningMutations.isEmpty)

        let network = try await repository.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in
            (repository.localOperation?.kind, repository.networkOperation?.kind)
        }
        #expect(network.0 == nil && network.1 == .fetch)
        #expect(repository.networkOperation == nil)
        await app.idle()
    }

    @Test("relays progress, scaled, with the latest value winning")
    func progress() async throws {
        let (_, app, repository) = try await makeRepository()
        let seen = try await repository.perform(OperationDescriptor(kind: .checkoutBranch)) { ctx in
            let phase = ctx.progress.scaled(from: 0.5, to: 1)
            for value in [0.0, 0.5, 1.0] {
                phase.send(.checkout(CheckoutProgress(value: value, title: "Checking out", description: "Updating files", target: "main")))
            }
            for _ in 0..<20 {
                await Task.yield()
            }
            return repository.localOperation?.progress
        }
        guard case .checkout(let progress)? = seen else {
            Issue.record("Unexpected progress \(String(describing: seen))")
            return
        }
        #expect(progress.value == 1)
        #expect(progress.description == "Updating files")
        await app.idle()
    }

    @Test("relays hook progress and terminal output")
    func hooks() async throws {
        let (_, app, repository) = try await makeRepository()
        let seen = try await repository.perform(OperationDescriptor(kind: .commit)) { ctx in
            ctx.hooks.onHookProgress(.started(hookName: "pre-commit", abort: {}))
            ctx.hooks.onTerminalOutputAvailable { _ in TerminalOutputSubscription(unsubscribe: {}) }
            for _ in 0..<20 {
                await Task.yield()
            }
            let started = repository.localOperation?.hook
            ctx.hooks.onHookProgress(.failed(hookName: "pre-commit"))
            for _ in 0..<20 {
                await Task.yield()
            }
            return (started, repository.localOperation?.hook, repository.localOperation?.terminalOutput != nil)
        }
        #expect(seen.0 == HookActivity(name: "pre-commit", status: .running))
        #expect(seen.1 == HookActivity(name: "pre-commit", status: .failed))
        #expect(seen.2)
        await app.idle()
    }

    @Test("refreshes after success and after failure, with the descriptor's scope")
    func refreshAfter() async throws {
        let (_, app, repository) = try await makeRepository()
        let scheduler = repository.refreshScheduler

        let before = scheduler.passCount
        try await repository.perform(OperationDescriptor(kind: .createTag, refreshAfter: .refs)) { _ in }
        await repository.idle()
        #expect(scheduler.passCount == before + 1)
        #expect(scheduler.lastPassScope == .refs)
        #expect(scheduler.lastPassReasons == [.operation(.createTag)])

        let failure = await #expect(throws: OperationError.self) {
            try await repository.perform(OperationDescriptor(kind: .deleteTag)) { _ -> Void in
                throw BodyFailure()
            }
        }
        #expect(failure?.operation == .deleteTag)
        await repository.idle()
        #expect(scheduler.passCount == before + 2)
        #expect(scheduler.lastPassScope == .full)
        #expect(scheduler.lastPassReasons == [.operation(.deleteTag)])
        await app.idle()
    }

    @Test("a user operation is busy behind another user operation")
    func busy() async throws {
        let (_, app, repository) = try await makeRepository()
        let gate = Gate()
        let first = Task {
            try await repository.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilWaiting()
        let second = await #expect(throws: OperationError.self) {
            try await repository.perform(OperationDescriptor(kind: .checkoutBranch)) { _ in }
        }
        #expect(second?.reason == .busy(.commit))
        #expect(second?.operation == .checkoutBranch)
        #expect(second?.repositoryID == repository.id)
        gate.open()
        try await first.value
        await app.idle()
    }

    @Test("a user operation waits behind background work")
    func waitsBehindBackground() async throws {
        let (_, app, repository) = try await makeRepository()
        let gate = Gate()
        let background = Task {
            try await repository.performIfIdle(OperationDescriptor(kind: .pruneBranches, policy: .background)) { _ in
                await gate.wait()
                return "pruned"
            }
        }
        await gate.waitUntilWaiting()
        let user = Task {
            try await repository.perform(OperationDescriptor(kind: .checkoutBranch)) { _ in
                repository.localOperation?.kind
            }
        }
        await settle()
        #expect(repository.localOperation?.kind == .pruneBranches)
        gate.open()
        #expect(try await background.value == "pruned")
        #expect(try await user.value == .checkoutBranch)
        await app.idle()
    }

    @Test("background work skips when a lane is busy")
    func backgroundSkips() async throws {
        let (_, app, repository) = try await makeRepository()
        let gate = Gate()
        let user = Task {
            try await repository.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilWaiting()
        let skipped = try await repository.performIfIdle(OperationDescriptor(kind: .fetch, lanes: [.network], policy: .background)) { _ in
            "fetched"
        }
        #expect(skipped == nil)
        gate.open()
        try await user.value
        await app.idle()
    }

    @Test("keeps the last background failure, never thrown at the user")
    func backgroundFailure() async throws {
        let (_, app, repository) = try await makeRepository()
        let error = await #expect(throws: OperationError.self) {
            try await repository.performIfIdle(OperationDescriptor(kind: .fetch, lanes: [.network], policy: .background)) { ctx in
                #expect(ctx.isBackgroundTask)
                #expect(ctx.hooks.onHookFailure == nil)
                throw gitError("fatal: unable to access 'https://example.com/x.git/': Could not resolve host: example.com\n")
            }
        }
        #expect(error?.isBackgroundTask == true)
        let failure = try #require(repository.lastBackgroundFailure)
        #expect(failure.error.operation == .fetch)
        #expect(failure.error.isBackgroundTask)
        await app.idle()
    }

    @Test("the last background failure stays until an operation of its kind succeeds, in the background or not")
    func backgroundFailureClears() async throws {
        let (_, app, repository) = try await makeRepository()
        let backgroundFetch = OperationDescriptor(kind: .fetch, lanes: [.network], policy: .background)
        let failAFetch = {
            _ = try? await repository.performIfIdle(backgroundFetch) { _ in
                throw gitError("fatal: unable to access 'https://example.com/x.git/': Could not resolve host: example.com\n")
            }
        }

        await failAFetch()
        #expect(repository.lastBackgroundFailure?.error.operation == .fetch)
        // Another kind of operation leaves it.
        try await repository.perform(OperationDescriptor(kind: .push, lanes: [.network])) { _ in }
        #expect(repository.lastBackgroundFailure?.error.operation == .fetch)
        // A user's fetch clears it.
        try await repository.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in }
        #expect(repository.lastBackgroundFailure == nil)

        // So does a background fetch.
        await failAFetch()
        #expect(repository.lastBackgroundFailure?.error.operation == .fetch)
        _ = try await repository.performIfIdle(backgroundFetch) { _ in }
        #expect(repository.lastBackgroundFailure == nil)
        await app.idle()
    }

    @Test("the body runs in its own task: cancelling the caller doesn't reach it")
    func cancellationShielding() async throws {
        let (_, app, repository) = try await makeRepository()
        let gate = Gate()
        let caller = Task {
            try await repository.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
                return Task.isCancelled
            }
        }
        await gate.waitUntilWaiting()
        caller.cancel()
        await settle()
        #expect(repository.localOperation?.kind == .commit)
        gate.open()
        #expect(try await caller.value == false)
        await app.idle()
    }

    @Test("a hook the user aborts ends the operation as a cancellation")
    func hookAborted() async throws {
        let (harness, app, repository) = try await makeRepository(responder: PromptResponder.hookFailures(.abort))
        let error = await #expect(throws: OperationError.self) {
            try await repository.perform(OperationDescriptor(kind: .commit, gitContext: .commit)) { ctx in
                let onHookFailure = try #require(ctx.hooks.onHookFailure)
                #expect(await onHookFailure("pre-commit", "lint failed\n") == .abort)
                #expect(ctx.hooks.abortedHook == "pre-commit")
                throw gitError("error: pre-commit hook failed\n", exitCode: 1)
            }
        }
        #expect(error?.reason == .cancelled(.hookAborted("pre-commit")))
        #expect(error?.isCancellation == true)
        #expect(harness.prompts.history == [.hookFailed(hookName: "pre-commit", terminalOutput: "lint failed\n")])
        await app.idle()
    }

    @Test("aborting the running hook ends the operation as a cancellation")
    func abortRunningHook() async throws {
        let (_, app, repository) = try await makeRepository()
        let gate = Gate()
        let aborted = Flag()
        let operation = Task {
            try await repository.perform(OperationDescriptor(kind: .commit)) { ctx in
                ctx.hooks.onHookProgress(.started(hookName: "pre-push", abort: {
                    Task { @MainActor in aborted.set() }
                }))
                await gate.wait()
                throw gitError("error: failed to push some refs\n", exitCode: 1)
            }
        }
        await gate.waitUntilWaiting()
        repository.abortRunningHook()
        gate.open()
        let error = await #expect(throws: OperationError.self) {
            try await operation.value
        }
        #expect(error?.reason == .cancelled(.hookAborted("pre-push")))
        await settle()
        #expect(aborted.isSet)
        await app.idle()
    }

    @Test("an operation finding the repository gone marks it missing")
    func marksMissing() async throws {
        let (_, app, repository) = try await makeRepository()
        let error = await #expect(throws: OperationError.self) {
            try await repository.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in
                throw gitError("fatal: not a git repository (or any of the parent directories): .git\n")
            }
        }
        #expect(error?.reason == .missingRepository)
        #expect(repository.record.isMissing)
        #expect(app.record(repository.id)?.isMissing == true)
        #expect(repository.availability == .missing)
        #expect(app.indicators[repository.id] == nil)
        await app.idle()
    }
}
