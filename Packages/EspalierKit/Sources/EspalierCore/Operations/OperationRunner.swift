import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "operations")

extension RepositoryModel {
    /// Runs an operation in the repository.
    ///
    /// 1. Acquires the descriptor's lanes, network before local (`busy`
    ///    behind a user operation; a user operation waits behind background
    ///    work).
    /// 2. Publishes the activity, suspends the watcher, holds refreshes for
    ///    local operations, and invalidates the refresh in flight.
    /// 3. Runs `body` in its own task, so cancelling the caller never reaches
    ///    git, inside the environment's runtimes. Only the user's Stop
    ///    (`stopOperation(_:)`) cancels that task.
    /// 4. On failure: a hook the user aborted becomes
    ///    `cancelled(.hookAborted)`, an operation the user stopped
    ///    `cancelled(.userCancelled)`; anything else is classified, with its
    ///    side effects (marking the repository missing), and a background
    ///    failure is kept in `lastBackgroundFailure`. On success, a kept
    ///    failure of the same kind is cleared. Neither happens without
    ///    `updatesBackgroundFailure`.
    /// 5. Always clears the activity, resumes the watcher, requests the
    ///    descriptor's refresh, and releases the hold and the lanes. With
    ///    `showsProgressUntilRefreshed`, the network activity stays until
    ///    that refresh has loaded.
    ///
    /// Intents that need fresh state before returning (commit, checkout)
    /// then await `awaitOperationRefresh(covering:)`.
    func perform<T: Sendable>(
        _ descriptor: OperationDescriptor,
        _ body: @escaping @MainActor (OperationContext) async throws -> T
    ) async throws(OperationError) -> T {
        guard let value = try await run(descriptor, body) else {
            throw OperationError(
                .busy(descriptor.kind),
                operation: descriptor.kind,
                repositoryID: id,
                isBackgroundTask: descriptor.isBackgroundTask
            )
        }
        return value
    }

    /// Runs an operation unless a lane it needs is taken, for background
    /// work: returns nil when it was skipped.
    func performIfIdle<T: Sendable>(
        _ descriptor: OperationDescriptor,
        _ body: @escaping @MainActor (OperationContext) async throws -> T
    ) async throws(OperationError) -> T? {
        try await run(descriptor, body)
    }

    private func run<T: Sendable>(
        _ descriptor: OperationDescriptor,
        _ body: @escaping @MainActor (OperationContext) async throws -> T
    ) async throws(OperationError) -> T? {
        operationDidStart()
        defer { operationDidEnd() }

        // The user's shell environment loads at launch; an operation waits
        // for it, so a commit made right away is still signed with the
        // shell's `gpg`, and a fetch finds its SSH agent.
        await environment.git.shellEnvironment?.waitUntilLoaded()

        let operation = ActiveOperation(
            kind: descriptor.kind,
            startedAt: environment.scheduler.now,
            isBackgroundTask: descriptor.isBackgroundTask
        )

        // 1. Lanes, network before local.
        var lanes: [OperationLane] = []
        if descriptor.lanes.contains(.network) {
            lanes.append(networkLane)
        }
        if descriptor.lanes.contains(.local) {
            lanes.append(localLane)
        }
        var acquired: [OperationLane] = []
        for lane in lanes {
            let result = await lane.acquire(for: operation, policy: descriptor.policy)
            switch result {
            case .acquired:
                acquired.append(lane)
            case .skipped:
                release(acquired, operation)
                logger.debug("Skipped background \(descriptor.kind.rawValue, privacy: .public): the \(lane.name, privacy: .public) lane is busy")
                return nil
            case .busy(let kind):
                release(acquired, operation)
                throw OperationError(
                    .busy(kind),
                    operation: descriptor.kind,
                    repositoryID: id,
                    retry: descriptor.retry,
                    isBackgroundTask: descriptor.isBackgroundTask,
                    gitContext: descriptor.gitContext
                )
            case .cancelled:
                release(acquired, operation)
                throw OperationError(
                    .cancelled(.taskCancelled),
                    operation: descriptor.kind,
                    repositoryID: id,
                    isBackgroundTask: descriptor.isBackgroundTask
                )
            }
        }

        // 2. Activity, watcher, refreshes.
        publish(operation, lanes: descriptor.lanes)
        let isLocal = descriptor.lanes.contains(.local) || descriptor.lanes.isEmpty
        let suspension = watcher.suspend(isLocal ? .everything : .gitDirectory)
        let hold = isLocal ? refreshScheduler.hold() : nil
        refreshScheduler.invalidateInFlight()

        // 3. The context.
        let hookState = HookState()
        hookStates[operation.id] = hookState
        let stop = OperationStop()
        operationStops[operation.id] = stop
        let context = makeContext(for: operation, descriptor: descriptor, hookState: hookState, stop: stop)

        // 4. The body, in a task of its own, which the user's Stop cancels.
        let environment = environment
        let task = Task { @MainActor () async -> Result<T, any Error> in
            do {
                return .success(try await environment.withRuntimes {
                    try await body(context)
                })
            } catch {
                return .failure(error)
            }
        }
        stop.setCancel { task.cancel() }
        let result = await task.value

        let outcome: Result<T, OperationError>
        switch result {
        case .success(let value):
            if descriptor.updatesBackgroundFailure, lastBackgroundFailure?.error.operation == descriptor.kind {
                lastBackgroundFailure = nil
            }
            outcome = .success(value)
        case .failure(let error):
            let operationError = await classify(error, descriptor: descriptor, hookState: hookState, stop: stop)
            applySideEffects(of: operationError)
            if descriptor.updatesBackgroundFailure, operationError.isBackgroundTask, !operationError.isCancellation {
                lastBackgroundFailure = BackgroundFailure(error: operationError, date: environment.scheduler.now)
            }
            if !operationError.isCancellation {
                logger.error("\(descriptor.kind.rawValue, privacy: .public) failed: \(operationError.message, privacy: .private)")
            }
            outcome = .failure(operationError)
        }

        // 5. Always.
        hookStates[operation.id] = nil
        operationStops[operation.id] = nil
        let showsProgressUntilRefreshed = descriptor.showsProgressUntilRefreshed
            && descriptor.lanes.contains(.network)
            && !descriptor.refreshAfter.isEmpty
        if showsProgressUntilRefreshed {
            clearLocalActivity(operation.id)
        } else {
            clearActivity(operation.id)
        }
        watcher.resume(suspension, covering: descriptor.refreshAfter)
        requestRefresh(descriptor.refreshAfter, options: descriptor.refreshOptions, reason: .operation(descriptor.kind))
        if let hold {
            refreshScheduler.release(hold)
        }
        release(acquired, operation)
        if showsProgressUntilRefreshed {
            await awaitOperationRefresh(covering: descriptor.refreshAfter)
            clearActivity(operation.id)
        }

        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    /// Waits for the refresh the last operation requested (`refreshAfter`)
    /// to apply, without requesting another: what an intent awaits before it
    /// returns when its caller expects fresh state.
    func awaitOperationRefresh(covering scope: RefreshScope) async {
        await refreshScheduler.waitForRequestedPass(covering: scope)
    }

    private func release(_ lanes: [OperationLane], _ operation: ActiveOperation) {
        for lane in lanes.reversed() {
            lane.release(operation)
        }
    }

    /// Stops the running operation `id` for the user: a hook it runs is
    /// aborted (the operation fails as `cancelled(.hookAborted)`, as a hook
    /// failure the user aborts does), otherwise its work stops
    /// (`OperationStop`, `cancelled(.userCancelled)`). Returns whether
    /// anything stopped.
    @discardableResult
    func stopOperation(_ id: UUID) -> Bool {
        if hookStates[id]?.abortRunningHook() == true {
            return true
        }
        return operationStops[id]?.stop() ?? false
    }

    private func makeContext(
        for operation: ActiveOperation,
        descriptor: OperationDescriptor,
        hookState: HookState,
        stop: OperationStop
    ) -> OperationContext {
        let id = operation.id
        let hookRelay = ProgressRelay<HookActivity> { [weak self] activity in
            self?.updateActivity(id) { $0.hook = activity }
        }
        let progressRelay = ProgressRelay<AnyProgress> { [weak self] progress in
            self?.updateActivity(id) { $0.progress = progress }
        }
        let outputRelay = ProgressRelay<TerminalOutputListener> { [weak self] listener in
            self?.updateActivity(id) { $0.terminalOutput = listener }
        }

        let prompts = environment.prompts
        var onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?
        if !descriptor.isBackgroundTask {
            onHookFailure = { @Sendable hookName, terminalOutput in
                let resolution = await prompts.promptHookFailure(hookName: hookName, terminalOutput: terminalOutput)
                if resolution == .abort {
                    hookState.recordAbort(hookName)
                }
                return resolution
            }
        }

        let hooks = HookCallbacks(
            onHookProgress: { progress in
                hookState.record(progress)
                let status: HookActivity.Status = switch progress {
                case .started: .running
                case .finished: .finished
                case .failed: .failed
                }
                hookRelay.send(HookActivity(name: progress.hookName, status: status))
            },
            onHookFailure: onHookFailure,
            onTerminalOutputAvailable: { subscribe in
                outputRelay.send(subscribe)
            },
            state: hookState
        )

        return OperationContext(
            repository: record.gitRepository,
            kind: descriptor.kind,
            isBackgroundTask: descriptor.isBackgroundTask,
            hooks: hooks,
            progress: ProgressSink(relay: progressRelay),
            gitHubHTMLURL: record.gitHubRepository.map { getHTMLURL($0.endpoint) },
            mainWorktreePath: record.mainWorktreePath,
            stop: stop
        )
    }

    private func classify(_ error: any Error, descriptor: OperationDescriptor, hookState: HookState, stop: OperationStop) async -> OperationError {
        if let hookName = hookState.abortedHook {
            return OperationError(
                .cancelled(.hookAborted(hookName)),
                operation: descriptor.kind,
                repositoryID: id,
                retry: descriptor.retry,
                isBackgroundTask: descriptor.isBackgroundTask,
                underlying: error,
                gitContext: descriptor.gitContext
            )
        }
        if stop.isStopped {
            return OperationError(
                .cancelled(.userCancelled),
                operation: descriptor.kind,
                repositoryID: id,
                retry: descriptor.retry,
                isBackgroundTask: descriptor.isBackgroundTask,
                underlying: error,
                gitContext: descriptor.gitContext
            )
        }
        var context = ClassificationContext()
        context.isBackgroundTask = descriptor.isBackgroundTask
        let account = app?.accounts.account(for: record)
        context.hasAccountForRepository = account != nil
        context.applicationSettingsURL = account.flatMap(GitHubWebURLs.applicationSettings(for:))
        switch gitState.tip {
        case .unborn:
            context.isUnbornBranch = true
        case .detached:
            context.isDetachedHead = true
        case .unknown, .valid:
            break
        }
        if (error as? GitError)?.result.gitError == .rebaseAlreadyInProgress {
            context.leftoverRebase = await getLeftoverRebase(record.gitRepository)
        }
        return await ErrorClassifier.classify(error, descriptor: descriptor, record: record, context: context)
    }

    private func applySideEffects(of error: OperationError) {
        if case .missingRepository = error.reason, !record.isMissing {
            app?.setMissing(true, for: id)
        }
    }
}
