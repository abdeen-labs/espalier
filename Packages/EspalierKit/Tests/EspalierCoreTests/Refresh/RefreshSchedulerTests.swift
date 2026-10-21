// Coalescing, holds, epoch discard, what an invalidated pass hadn't applied
// running again after the operation, `refresh` waiting only for a covering
// pass that loads its scope, past passes an operation invalidates, and
// `waitForRequestedPass` waiting for the passes that apply what was
// requested; then the same for a repository's real passes.
//
// The waits are continuations the passes and tasks resume, never polling or
// counting yields, so the tests take the same few steps however busy the
// main actor is (and however it orders its jobs); a pass that never starts
// or finishes, or a wait that never ends, runs into the suite's hang guard.
// Whether a caller still waits is read from the scheduler, which updates it
// at once.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport

/// Passes that run until the test finishes them.
@MainActor
private final class ControlledPasses {
    struct Pass {
        let scope: RefreshScope
        let options: RefreshOptions
        let token: RefreshPassToken
    }

    private(set) var started: [Pass] = []
    private(set) var finished = 0
    private(set) var sawCancellation: [Bool] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func run(_ scope: RefreshScope, _ options: RefreshOptions, _ token: RefreshPassToken) async {
        started.append(Pass(scope: scope, options: options, token: token))
        resume(&startWaiters, reaching: started.count)
        await withCheckedContinuation { gates.append($0) }
        sawCancellation.append(Task.isCancelled)
        finished += 1
        // The pass's task goes on to the scheduler's end-of-pass handling
        // without suspending, so the finish waiter sees what it did.
        resume(&finishWaiters, reaching: finished)
    }

    private func resume(_ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)], reaching count: Int) {
        let ready = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Waits until `count` passes have started.
    func waitForStarted(_ count: Int) async {
        guard started.count < count else {
            return
        }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    /// Finishes the running pass, once it has started, and waits until the
    /// scheduler has handled its end (the next pass, if any, is queued to
    /// start; `waitForStarted` waits for it).
    func finishCurrent() async {
        await waitForStarted(finished + 1)
        let count = finished + 1
        gates.removeFirst().resume()
        await withCheckedContinuation { finishWaiters.append((count, $0)) }
    }
}

/// Starts `body` in a task on the main actor and returns once the task has
/// run up to its first suspension: the task resumes this wait as it starts,
/// and the main actor runs nothing else until the task suspends (a
/// scheduler wait registers before it suspends).
@MainActor
private func startTask(_ body: @escaping @MainActor @Sendable () async -> Void) async -> Task<Void, Never> {
    var task: Task<Void, Never>?
    await withCheckedContinuation { (running: CheckedContinuation<Void, Never>) in
        task = Task { @MainActor in
            running.resume()
            await body()
        }
    }
    return task!
}

@Suite("Refresh scheduler", .hangGuard(minutes: 5)) @MainActor
struct RefreshSchedulerTests {
    private func makeScheduler() -> (RefreshScheduler, ControlledPasses) {
        let passes = ControlledPasses()
        let scheduler = RefreshScheduler { scope, options, token in
            await passes.run(scope, options, token)
        }
        return (scheduler, passes)
    }

    @Test("starts a pass at once and merges what's requested meanwhile into one queued pass")
    func coalescing() async {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.status, reason: .fileSystem)
        await passes.waitForStarted(1)
        #expect(scheduler.passCount == 1)
        #expect(passes.started.first?.scope == .status)

        scheduler.request(.refs, reason: .fileSystem)
        scheduler.request(.metadata, options: .clearPartialSelections, reason: .operation(.commit))
        scheduler.request(.refs, reason: .user)
        #expect(scheduler.passCount == 1)
        #expect(!scheduler.isIdle)

        await passes.finishCurrent()
        #expect(scheduler.passCount == 2)
        await passes.waitForStarted(2)
        #expect(passes.started.count == 2)
        #expect(passes.started.last?.scope == [.refs, .metadata])
        #expect(passes.started.last?.options == .clearPartialSelections)
        #expect(scheduler.lastPassReasons == [.fileSystem, .operation(.commit), .user])

        await passes.finishCurrent()
        #expect(scheduler.isIdle)
        #expect(scheduler.passCount == 2)
    }

    @Test("ignores requests for nothing")
    func emptyScope() async {
        let (scheduler, _) = makeScheduler()
        scheduler.request([], reason: .user)
        await scheduler.refresh([], reason: .user)
        #expect(scheduler.passCount == 0)
        #expect(scheduler.isIdle)
    }

    @Test("a hold keeps passes from starting; requests accumulate and run when the last hold ends")
    func holds() async {
        let (scheduler, passes) = makeScheduler()
        let first = scheduler.hold()
        let second = scheduler.hold()
        scheduler.request(.status, reason: .fileSystem)
        scheduler.request(.refs, reason: .operation(.commit))
        #expect(scheduler.passCount == 0)
        // Queued behind a hold counts as idle: the operation holding it ends
        // first.
        #expect(scheduler.isIdle)

        scheduler.release(first)
        #expect(scheduler.passCount == 0)

        scheduler.release(second)
        await passes.waitForStarted(1)
        #expect(passes.started.first?.scope == [.status, .refs])
        await passes.finishCurrent()
        #expect(scheduler.isIdle)
    }

    @Test("an operation starting invalidates the pass in flight, which applies no more steps")
    func epochDiscard() async throws {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, reason: .selection)
        await passes.waitForStarted(1)
        let token = try #require(passes.started.first).token
        #expect(token.isCurrent)

        let hold = scheduler.hold()
        scheduler.invalidateInFlight()
        #expect(!token.isCurrent)
        await passes.finishCurrent()
        #expect(passes.sawCancellation == [true])

        // A pass started after the operation is current again.
        scheduler.request(.status, reason: .operation(.checkoutBranch))
        scheduler.release(hold)
        await passes.waitForStarted(2)
        #expect(passes.started.last?.token.isCurrent == true)
        await passes.finishCurrent()
        #expect(scheduler.isIdle)
    }

    /// A `.full` pass with options, which an operation invalidates: what the
    /// pass had applied, the operation's refresh, and the one pass after the
    /// operation (an empty scope for none).
    struct InvalidatedPassCase: Sendable {
        let applied: RefreshScope
        let refreshAfter: RefreshScope
        let again: RefreshScope
        let options: RefreshOptions
        let reasons: [RefreshReason]
    }

    nonisolated static let invalidatedPassCases: [NamedCase<InvalidatedPassCase>] = [
        NamedCase("nothing applied, and the operation requests nothing", InvalidatedPassCase(
            applied: [], refreshAfter: [],
            again: .full, options: .clearPartialSelections, reasons: [.operation(.commit)]
        )),
        // The options went with the status.
        NamedCase("the status applied", InvalidatedPassCase(
            applied: .status, refreshAfter: [],
            again: [.refs, .remotes, .metadata], options: [], reasons: [.operation(.commit)]
        )),
        NamedCase("everything applied", InvalidatedPassCase(
            applied: .full, refreshAfter: [],
            again: [], options: [], reasons: []
        )),
        NamedCase("the operation's refresh covering what's left", InvalidatedPassCase(
            applied: .status, refreshAfter: .full,
            again: .full, options: [], reasons: [.operation(.commit), .operation(.createTag)]
        )),
        NamedCase("the operation's refresh covering part of what's left", InvalidatedPassCase(
            applied: [], refreshAfter: .refs,
            again: .full, options: .clearPartialSelections, reasons: [.operation(.commit), .operation(.createTag)]
        )),
    ]

    @Test(
        "a pass an operation invalidates requests again what it hadn't applied, which runs after the operation in one pass with its refresh",
        arguments: invalidatedPassCases
    )
    func invalidatedPassRequestsAgain(_ testCase: NamedCase<InvalidatedPassCase>) async throws {
        let value = testCase.value
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, options: .clearPartialSelections, reason: .operation(.commit))
        await passes.waitForStarted(1)
        if !value.applied.isEmpty {
            try #require(passes.started.first).token.didApply(value.applied)
        }

        // A local operation starts, holding passes, and nobody waits for the
        // pass it invalidates.
        let hold = scheduler.hold()
        scheduler.invalidateInFlight()
        await passes.finishCurrent()
        #expect(scheduler.passCount == 1)
        #expect(scheduler.isIdle)

        // It ends: it requests its refresh and releases the hold.
        scheduler.request(value.refreshAfter, reason: .operation(.createTag))
        scheduler.release(hold)
        if value.again.isEmpty {
            #expect(scheduler.passCount == 1)
        } else {
            await passes.waitForStarted(2)
            #expect(passes.started.last?.scope == value.again)
            #expect(passes.started.last?.options == value.options)
            #expect(scheduler.lastPassReasons == value.reasons)
            await passes.finishCurrent()
            #expect(scheduler.passCount == 2)
        }
        #expect(scheduler.isIdle)
    }

    @Test("refresh waits for a pass that started after the call and covers the scope")
    func refreshWaitsForCoveringPass() async {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.status, reason: .fileSystem)
        await passes.waitForStarted(1)

        let refreshed = Flag()
        let waiting = await startTask {
            await scheduler.refresh(.status, reason: .operation(.commit))
            refreshed.set()
        }
        #expect(scheduler.waitingCount == 1)

        // The pass in flight started before the call: it doesn't count.
        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 1)
        #expect(!refreshed.isSet)
        #expect(scheduler.passCount == 2)

        await passes.finishCurrent()
        await waiting.value
        #expect(refreshed.isSet)
    }

    @Test("refresh ignores passes that don't cover its scope")
    func refreshIgnoresNarrowerPasses() async {
        let (scheduler, passes) = makeScheduler()
        let hold = scheduler.hold()
        scheduler.request(.status, reason: .fileSystem)
        let refreshed = Flag()
        let waiting = await startTask {
            await scheduler.refresh(.refs, reason: .user)
            refreshed.set()
        }
        scheduler.release(hold)
        await passes.waitForStarted(1)
        // The one queued pass merged both requests.
        #expect(passes.started.first?.scope == [.status, .refs])
        await passes.finishCurrent()
        await waiting.value
        #expect(refreshed.isSet)

        // A narrower pass in flight doesn't satisfy a wider refresh.
        scheduler.request(.metadata, reason: .fileSystem)
        await passes.waitForStarted(2)
        let wider = Flag()
        let widerWaiting = await startTask {
            await scheduler.refresh(.full, reason: .user)
            wider.set()
        }
        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 1)
        #expect(!wider.isSet)
        await passes.finishCurrent()
        await widerWaiting.value
        #expect(wider.isSet)
    }

    @Test("a refresh whose pass an operation invalidates waits for the pass after the operation, which loads its scope")
    func refreshOutlivesInvalidation() async {
        let (scheduler, passes) = makeScheduler()
        let refreshed = Flag()
        let waiting = await startTask {
            await scheduler.refresh(.full, reason: .selection)
            refreshed.set()
        }
        await passes.waitForStarted(1)

        // A local operation starts: it holds passes and invalidates the one
        // in flight.
        let hold = scheduler.hold()
        scheduler.invalidateInFlight()
        await passes.finishCurrent()
        #expect(passes.sawCancellation == [true])
        // The refresh still waits; what it asked for is queued behind the
        // hold, though the operation requests nothing.
        #expect(scheduler.waitingCount == 1)
        #expect(scheduler.passCount == 1)
        #expect(scheduler.isIdle)

        scheduler.release(hold)
        await passes.waitForStarted(2)
        #expect(passes.started.last?.scope == .full)
        #expect(scheduler.lastPassReasons == [.selection])
        #expect(passes.started.last?.token.isCurrent == true)
        await passes.finishCurrent()
        await waiting.value
        #expect(refreshed.isSet)
        #expect(scheduler.isIdle)
    }

    @Test("an invalidated pass hands on only the waiters it hadn't loaded for, merged with what's queued")
    func invalidationHandsOnUnloadedWaiters() async throws {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, options: .clearPartialSelections, reason: .operation(.commit))
        await passes.waitForStarted(1)
        let statusWaiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .status)
        }
        let everything = Flag()
        let fullWaiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .full)
            everything.set()
        }
        let refsRefreshed = Flag()
        let refsWaiting = await startTask {
            await scheduler.refresh(.refs, reason: .user)
            refsRefreshed.set()
        }
        #expect(scheduler.waitingCount == 3)

        // The status lands, then a network operation (no hold) invalidates
        // the pass and requests its own refresh.
        try #require(passes.started.first).token.didApply(.status)
        await statusWaiting.value
        scheduler.invalidateInFlight()
        scheduler.request(.metadata, reason: .operation(.fetch))
        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 2)
        #expect(!everything.isSet)

        // One pass loads what the waiters still need, with what was queued:
        // the refs refresh queued behind the first pass, the full one handed
        // on, and the operation's.
        await passes.waitForStarted(2)
        #expect(passes.started.last?.scope == .full)
        #expect(scheduler.lastPassReasons == [.user, .operation(.fetch), .operation(.commit)])
        await passes.finishCurrent()
        await fullWaiting.value
        await refsWaiting.value
        #expect(everything.isSet)
        #expect(refsRefreshed.isSet)
        #expect(scheduler.passCount == 2)
    }

    @Test("a refresh whose passes keep being invalidated waits through each")
    func repeatedInvalidation() async {
        let (scheduler, passes) = makeScheduler()
        let refreshed = Flag()
        let waiting = await startTask {
            await scheduler.refresh(.status, reason: .user)
            refreshed.set()
        }
        for count in 1...3 {
            await passes.waitForStarted(count)
            scheduler.invalidateInFlight()
            await passes.finishCurrent()
            #expect(scheduler.waitingCount == 1)
        }
        await passes.waitForStarted(4)
        await passes.finishCurrent()
        await waiting.value
        #expect(refreshed.isSet)
        #expect(passes.sawCancellation == [true, true, true, false])
    }

    @Test("a refresh whose task is cancelled stops waiting")
    func refreshCancellation() async {
        let (scheduler, passes) = makeScheduler()
        let hold = scheduler.hold()
        let waiting = await startTask {
            await scheduler.refresh(.status, reason: .user)
        }
        #expect(scheduler.waitingCount == 1)
        waiting.cancel()
        // Returns while the hold keeps its pass from starting (the suite's
        // hang guard fails the test if it doesn't).
        await waiting.value
        #expect(scheduler.waitingCount == 0)
        #expect(scheduler.passCount == 0)
        #expect(passes.started.isEmpty)

        // The request it made still runs.
        scheduler.release(hold)
        await passes.waitForStarted(1)
        #expect(passes.started.first?.scope == .status)
        await passes.finishCurrent()
        #expect(scheduler.isIdle)
    }

    @Test("waits for the pass that applies what was requested, without requesting anything")
    func waitForRequestedPass() async {
        let (scheduler, passes) = makeScheduler()
        // Nothing requested: returns at once.
        await scheduler.waitForRequestedPass(covering: .status)
        #expect(scheduler.passCount == 0)

        scheduler.request(.full, reason: .selection)
        await passes.waitForStarted(1)
        let done = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .status)
            done.set()
        }
        #expect(scheduler.waitingCount == 1)
        #expect(!done.isSet)
        await passes.finishCurrent()
        await waiting.value
        #expect(done.isSet)
        #expect(scheduler.passCount == 1)
    }

    @Test("a waiter that needs only the status goes on once the pass applies it")
    func partialApplication() async throws {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, options: .clearPartialSelections, reason: .operation(.commit))
        await passes.waitForStarted(1)
        let statusApplied = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .status)
            statusApplied.set()
        }
        let everything = Flag()
        let waitingForEverything = await startTask {
            await scheduler.waitForRequestedPass(covering: .full)
            everything.set()
        }
        #expect(scheduler.waitingCount == 2)
        #expect(!statusApplied.isSet)

        try #require(passes.started.first).token.didApply(.status)
        #expect(scheduler.waitingCount == 1)
        await waiting.value
        #expect(statusApplied.isSet)
        #expect(!everything.isSet)
        #expect(scheduler.isRunning)

        await passes.finishCurrent()
        await waitingForEverything.value
        #expect(everything.isSet)
    }

    @Test("a wait for what was requested ends with the pass in flight that covers the scope, though a narrower request is queued behind it")
    func waitEndsWithCoveringPassInFlight() async {
        let (scheduler, passes) = makeScheduler()
        // An operation's refresh runs, and the watcher asks for the status
        // meanwhile.
        scheduler.request(.full, reason: .operation(.pull))
        await passes.waitForStarted(1)
        scheduler.request(.status, reason: .fileSystem)
        let done = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .full)
            done.set()
        }
        #expect(scheduler.waitingCount == 1)

        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 0)
        await waiting.value
        #expect(done.isSet)

        // The status pass runs on its own.
        await passes.waitForStarted(2)
        #expect(passes.started.last?.scope == .status)
        await passes.finishCurrent()
        #expect(scheduler.isIdle)
    }

    @Test("a wait for what was requested returns at once when the pass that covers the scope has ended, though narrower ones run and are queued")
    func waitReturnsOnceCoveringPassEnded() async {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, reason: .operation(.pull))
        await passes.finishCurrent()
        scheduler.request(.status, reason: .fileSystem)
        await passes.waitForStarted(2)
        scheduler.request(.status, reason: .fileSystem)

        let done = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .full)
            done.set()
        }
        #expect(done.isSet)
        #expect(scheduler.waitingCount == 0)
        await waiting.value

        await passes.finishCurrent()
        await passes.finishCurrent()
        #expect(scheduler.passCount == 3)
        #expect(scheduler.isIdle)
    }

    /// A wait for what was requested, with a pass in flight and one queued
    /// behind it that applies the latest request for part of the scope.
    struct QueuedPassCase: Sendable {
        let inFlight: RefreshScope
        let queued: RefreshScope
        let waitingFor: RefreshScope
    }

    nonisolated static let queuedPassCases: [NamedCase<QueuedPassCase>] = [
        // An operation's refresh requested while a selection's pass runs.
        NamedCase("the same scope queued again", QueuedPassCase(inFlight: .full, queued: .full, waitingFor: .full)),
        NamedCase("a narrower scope queued that covers the wait", QueuedPassCase(inFlight: .full, queued: .status, waitingFor: .status)),
        NamedCase("the scope split between the two passes", QueuedPassCase(inFlight: .status, queued: .refs, waitingFor: [.status, .refs])),
    ]

    @Test("a wait for what was requested goes on to the queued pass when it applies the latest request for part of the scope", arguments: queuedPassCases)
    func waitForQueuedPass(_ testCase: NamedCase<QueuedPassCase>) async {
        let value = testCase.value
        let (scheduler, passes) = makeScheduler()
        scheduler.request(value.inFlight, reason: .selection)
        await passes.waitForStarted(1)
        scheduler.request(value.queued, reason: .fileSystem)
        let done = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: value.waitingFor)
            done.set()
        }
        #expect(scheduler.waitingCount == 1)

        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 1)
        #expect(!done.isSet)

        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 0)
        await waiting.value
        #expect(done.isSet)
    }

    @Test("a wait for what was requested whose covering pass an operation invalidates goes on to the pass after the operation")
    func waitHandedOn() async {
        let (scheduler, passes) = makeScheduler()
        scheduler.request(.full, reason: .operation(.pull))
        await passes.waitForStarted(1)
        scheduler.request(.status, reason: .fileSystem)
        let done = Flag()
        let waiting = await startTask {
            await scheduler.waitForRequestedPass(covering: .full)
            done.set()
        }

        let hold = scheduler.hold()
        scheduler.invalidateInFlight()
        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 1)
        #expect(!done.isSet)
        #expect(scheduler.isIdle)

        // One pass, with the queued status.
        scheduler.release(hold)
        await passes.waitForStarted(2)
        #expect(passes.started.last?.scope == .full)
        #expect(scheduler.lastPassReasons == [.fileSystem, .operation(.pull)])
        await passes.finishCurrent()
        #expect(scheduler.waitingCount == 0)
        await waiting.value
        #expect(done.isSet)
        #expect(scheduler.passCount == 2)
    }

    @Test("reports when passes run")
    func activity() async {
        let (scheduler, passes) = makeScheduler()
        var changes: [Bool] = []
        scheduler.onActivityChange = { changes.append($0) }
        scheduler.request(.status, reason: .fileSystem)
        await passes.waitForStarted(1)
        #expect(scheduler.isRunning)
        await passes.finishCurrent()
        #expect(!scheduler.isRunning)
        #expect(changes == [true, false])
    }
}

@Suite("Refreshes of a repository that an operation supersedes", .offline, .hangGuard(minutes: 5)) @MainActor
struct AwaitedRepositoryRefreshTests {
    @Test("a full refresh an operation supersedes returns once the pass after it has loaded the branches")
    func supersededFullRefresh() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        // A branch the repository's state doesn't know yet.
        try await runGit(["branch", "extra"], local)
        func knowsExtra() -> Bool {
            model.gitState.branches.all.contains { $0.name == "extra" }
        }
        #expect(!knowsExtra())

        // The next pass waits to run until the operation has started.
        let passStarted = Signal(), passMayRun = Signal()
        let run = model.refreshScheduler.runPass
        var isFirstPass = true
        model.refreshScheduler.runPass = { scope, options, token in
            if isFirstPass {
                isFirstPass = false
                passStarted.fire()
                await passMayRun.wait()
            }
            await run?(scope, options, token)
        }

        let refreshed = Signal()
        let refreshing = Task {
            await model.refresh(.full, reason: .user)
            refreshed.fire()
        }
        await passStarted.wait()

        // An operation that requests no refresh of its own starts, which
        // invalidates the pass.
        let operationStarted = Signal(), operationMayEnd = Signal()
        let operation = Task {
            try await model.perform(OperationDescriptor(kind: .createTag, refreshAfter: [])) { _ in
                operationStarted.fire()
                await operationMayEnd.wait()
            }
        }
        await operationStarted.wait()
        passMayRun.fire()
        await model.refreshScheduler.idle()
        // The superseded pass loaded nothing, and the refresh still waits.
        #expect(!knowsExtra())
        #expect(!refreshed.isFired)
        #expect(model.refreshScheduler.waitingCount == 1)

        operationMayEnd.fire()
        try await operation.value
        await refreshing.value
        #expect(knowsExtra())
        await app.idle()
    }

    @Test("a full refresh an operation cancels loads after it, though nobody waits for it and the operation requests none")
    func cancelledFullRefresh() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        try await runGit(["branch", "extra"], local)
        func knowsExtra() -> Bool {
            model.gitState.branches.all.contains { $0.name == "extra" }
        }
        #expect(!knowsExtra())

        // The next pass waits to run until the operation has started.
        let passStarted = Signal(), passMayRun = Signal()
        let run = model.refreshScheduler.runPass
        var isFirstPass = true
        model.refreshScheduler.runPass = { scope, options, token in
            if isFirstPass {
                isFirstPass = false
                passStarted.fire()
                await passMayRun.wait()
            }
            await run?(scope, options, token)
        }

        // The pass a selection requests, which background work cancels as it
        // starts.
        let passes = model.refreshScheduler.passCount
        model.requestRefresh(.full, reason: .selection)
        await passStarted.wait()
        let operationStarted = Signal(), operationMayEnd = Signal()
        let operation = Task {
            try await model.perform(OperationDescriptor(kind: .createTag, refreshAfter: [])) { _ in
                operationStarted.fire()
                await operationMayEnd.wait()
            }
        }
        await operationStarted.wait()
        passMayRun.fire()
        await model.refreshScheduler.idle()
        // The cancelled pass loaded nothing, and the rest waits behind the
        // operation.
        #expect(!knowsExtra())
        #expect(model.refreshScheduler.passCount == passes + 1)

        operationMayEnd.fire()
        try await operation.value
        await model.idle()
        #expect(knowsExtra())
        #expect(model.refreshScheduler.passCount == passes + 2)
        #expect(model.refreshScheduler.lastPassScope == .full)
        #expect(model.refreshScheduler.lastPassReasons == [.selection])
        await app.idle()
    }
}

/// A one-time event tasks on the main actor wait for.
@MainActor
private final class Signal {
    private(set) var isFired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        isFired = true
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isFired else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A flag set from tasks on the main actor.
@MainActor
final class Flag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}
