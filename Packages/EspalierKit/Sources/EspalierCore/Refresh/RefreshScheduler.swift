import Foundation

/// Lets a running pass check that its results still count, and report what
/// it has applied.
@MainActor
struct RefreshPassToken {
    private weak var scheduler: RefreshScheduler?
    let epoch: UInt64
    let sequence: Int

    init(scheduler: RefreshScheduler, epoch: UInt64, sequence: Int) {
        self.scheduler = scheduler
        self.epoch = epoch
        self.sequence = sequence
    }

    /// Whether the pass may apply its next step: no operation started since
    /// it began, and it wasn't cancelled.
    var isCurrent: Bool {
        guard let scheduler else {
            return false
        }
        return scheduler.epoch == epoch && !Task.isCancelled
    }

    /// The pass applied `scope`: waiters that only need it (a commit
    /// waiting for the status) can go on before the pass ends, and an
    /// operation that invalidates the pass doesn't request it again.
    func didApply(_ scope: RefreshScope) {
        scheduler?.passDidApply(scope, sequence: sequence)
    }
}

/// Stops passes from starting while a local operation runs.
struct RefreshHold: Hashable, Sendable {
    fileprivate let id: UUID
}

/// Schedules one repository's refresh passes.
///
/// - At most one pass is in flight. Everything requested meanwhile merges
///   (scopes and options) into the one queued pass, so passes never apply
///   out of order.
/// - A hold (taken by local-lane operations) keeps passes from starting;
///   requests accumulate and run when the last hold is released.
/// - `invalidateInFlight()` (an operation starting) bumps the epoch and
///   cancels the pass in flight, which stops applying. When it ends, what it
///   hadn't applied is requested again, so it merges with the operation's
///   own refresh and, behind the operation's hold, runs after it. Callers
///   waiting for that pass wait for a later one instead: what they asked
///   for is requested again too.
@MainActor
final class RefreshScheduler {
    typealias Pass = @MainActor (RefreshScope, RefreshOptions, RefreshPassToken) async -> Void

    private struct InFlight {
        let sequence: Int
        /// The epoch it started in: a later one means it was invalidated.
        let epoch: UInt64
        let scope: RefreshScope
        let options: RefreshOptions
        let reasons: [RefreshReason]
        let task: Task<Void, Never>
        /// What the pass has applied so far.
        var applied: RefreshScope = []
    }

    private struct Pending {
        var scope: RefreshScope
        var options: RefreshOptions
        var reasons: [RefreshReason]
    }

    private struct Waiter {
        let id: UUID
        /// What the waiter still needs; it goes on once no part is left.
        var parts: [WaitPart]
        let options: RefreshOptions
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Part of what a waiter needs, which one pass loads.
    private struct WaitPart {
        /// Only a pass with a later sequence covers the part.
        var after: Int
        let scope: RefreshScope
    }

    /// Runs one pass. Set by the repository model.
    var runPass: Pass?

    /// Called when a pass starts (true) or the last one ends (false).
    var onActivityChange: (@MainActor (Bool) -> Void)?

    /// Bumped by `invalidateInFlight()`.
    private(set) var epoch: UInt64 = 0

    private var inFlight: InFlight?
    private var pending: Pending?
    private var holds: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// For each scope component, the sequence of the pass that applies the
    /// latest request for it: the queued pass, the one in flight, or one that
    /// ended having loaded it (an invalidated pass requests again what it
    /// hadn't applied).
    private var requestedSequences: [RefreshScope: Int] = [:]
    /// For each scope component, the sequence of the latest pass that loaded
    /// it: applied it, or ran to its end with it in its scope.
    private var loadedSequences: [RefreshScope: Int] = [:]

    /// The number of passes started (for tests).
    private(set) var passCount = 0
    /// The scope of the last pass started (for tests).
    private(set) var lastPassScope: RefreshScope?
    /// The options of the last pass started (for tests).
    private(set) var lastPassOptions: RefreshOptions?
    /// Why the last pass started (for tests and logs).
    private(set) var lastPassReasons: [RefreshReason] = []
    /// How many callers wait for a pass or for idle (for tests).
    var waitingCount: Int {
        waiters.count + idleWaiters.count
    }

    init(runPass: Pass? = nil) {
        self.runPass = runPass
    }

    isolated deinit {
        for waiter in waiters {
            waiter.continuation.resume()
        }
        for waiter in idleWaiters {
            waiter.resume()
        }
    }

    /// Whether a pass is running.
    var isRunning: Bool {
        inFlight != nil
    }

    /// Whether a hold is in effect.
    var isHeld: Bool {
        !holds.isEmpty
    }

    /// Whether nothing is running and nothing is queued that could start
    /// (a request queued behind a hold starts when the operation ends).
    var isIdle: Bool {
        inFlight == nil && (pending == nil || isHeld)
    }

    /// Requests a pass covering `scope`. It starts at once if nothing is in
    /// flight and nothing holds; otherwise it merges into the queued pass.
    func request(_ scope: RefreshScope, options: RefreshOptions = [], reason: RefreshReason) {
        guard !scope.isEmpty else {
            return
        }
        enqueue(scope, options: options, reasons: [reason])
        startIfPossible()
    }

    /// Merges a request into the queued pass.
    private func enqueue(_ scope: RefreshScope, options: RefreshOptions, reasons: [RefreshReason]) {
        if var pending {
            pending.scope.formUnion(scope)
            pending.options.formUnion(options)
            pending.reasons.append(contentsOf: reasons)
            self.pending = pending
        } else {
            pending = Pending(scope: scope, options: options, reasons: reasons)
        }
        // The queued pass is the next to start.
        for component in Self.components(of: scope) {
            requestedSequences[component] = passCount + 1
        }
    }

    /// Requests a pass covering `scope` and waits until one that started
    /// after this call has loaded it: a pass that ran to its end, or applied
    /// the scope before an operation invalidated it. When an operation
    /// invalidates the pass first, the scope is requested again, and the
    /// wait goes on until the pass after the operation loads it.
    func refresh(_ scope: RefreshScope, options: RefreshOptions = [], reason: RefreshReason) async {
        guard !scope.isEmpty else {
            return
        }
        let after = passCount
        request(scope, options: options, reason: reason)
        await waitUntilLoaded([WaitPart(after: after, scope: scope)], options: options)
    }

    /// Waits, without requesting anything, until the passes that apply what
    /// has been requested for `scope` have loaded it.
    ///
    /// Each component of the scope (status, refs, remotes, metadata) was
    /// last requested of a pass: the queued one, the one in flight, or one
    /// that has ended. The wait starts from the oldest of those passes and
    /// ends once that pass or a later one has loaded every component. So the
    /// pass in flight that covers the scope ends the wait though a narrower
    /// request (a status the watcher asked for) is queued behind it, and the
    /// wait ends at once when that pass has already ended. A pass an
    /// operation invalidates first hands the wait on, as `refresh` does.
    /// Returns at once when nothing was requested for the scope.
    func waitForRequestedPass(covering scope: RefreshScope) async {
        var requested: [RefreshScope: Int] = [:]
        for component in Self.components(of: scope) {
            requested[component] = requestedSequences[component]
        }
        guard let oldest = requested.values.min() else {
            return
        }
        // What hasn't been loaded since the oldest pass, grouped by the pass
        // that applies its latest request, which covers each group.
        var unloaded: [Int: RefreshScope] = [:]
        for (component, sequence) in requested where (loadedSequences[component] ?? 0) < oldest {
            unloaded[sequence, default: []].formUnion(component)
        }
        guard !unloaded.isEmpty else {
            return
        }
        let parts = unloaded.keys.sorted().map { sequence in
            WaitPart(after: oldest - 1, scope: unloaded[sequence] ?? [])
        }
        await waitUntilLoaded(parts, options: [])
    }

    private func waitUntilLoaded(_ parts: [WaitPart], options: RefreshOptions) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, parts: parts, options: options, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume()
    }

    /// Keeps passes from starting until the hold is released.
    func hold() -> RefreshHold {
        let hold = RefreshHold(id: UUID())
        holds.insert(hold.id)
        resumeIdleWaitersIfIdle()
        return hold
    }

    /// Releases a hold; the queued pass starts when no hold remains.
    func release(_ hold: RefreshHold) {
        holds.remove(hold.id)
        startIfPossible()
        resumeIdleWaitersIfIdle()
    }

    /// Bumps the epoch and cancels the pass in flight (read-only git gets
    /// SIGTERM): it applies no more steps, and when it ends, what it hadn't
    /// applied is requested again.
    func invalidateInFlight() {
        epoch &+= 1
        inFlight?.task.cancel()
    }

    /// Waits until nothing runs and nothing is queued (see `isIdle`).
    func idle() async {
        while !isIdle {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    // MARK: Passes

    private func startIfPossible() {
        guard inFlight == nil, holds.isEmpty, let pending else {
            return
        }
        self.pending = nil

        passCount += 1
        let sequence = passCount
        let epoch = self.epoch
        lastPassScope = pending.scope
        lastPassOptions = pending.options
        lastPassReasons = pending.reasons

        let token = RefreshPassToken(scheduler: self, epoch: epoch, sequence: sequence)
        let runPass = self.runPass
        let scope = pending.scope
        let options = pending.options
        let task = Task { [weak self] in
            await runPass?(scope, options, token)
            self?.passDidFinish(sequence)
        }
        inFlight = InFlight(sequence: sequence, epoch: epoch, scope: scope, options: options, reasons: pending.reasons, task: task)
        onActivityChange?(true)
    }

    /// A pass reported applying `scope`: resumes the waiters it now covers.
    fileprivate func passDidApply(_ scope: RefreshScope, sequence: Int) {
        guard var current = inFlight, current.sequence == sequence else {
            return
        }
        current.applied.formUnion(scope)
        inFlight = current
        markLoaded(scope, sequence: sequence)
        resumeWaiters(coveredBy: current.applied, options: current.options, sequence: sequence)
    }

    private func passDidFinish(_ sequence: Int) {
        guard let finished = inFlight, finished.sequence == sequence else {
            return
        }
        inFlight = nil

        // A pass that ran to its end covers what it was asked for (a step
        // whose load failed stays as it was). One an operation invalidated
        // covers only what it applied before then: the rest is requested
        // again, and its other waiters wait for that later pass.
        if finished.epoch == epoch {
            markLoaded(finished.scope, sequence: sequence)
            resumeWaiters(coveredBy: finished.scope, options: finished.options, sequence: sequence)
        } else {
            requestAgain(finished)
        }

        startIfPossible()
        if inFlight == nil {
            onActivityChange?(false)
        }
        resumeIdleWaitersIfIdle()
    }

    /// An invalidated pass requests again what it hadn't applied, with what
    /// the waiters it would have covered need. That merges with what's
    /// queued (the operation's own refresh) and runs once no operation holds
    /// passes.
    private func requestAgain(_ finished: InFlight) {
        var scope = finished.scope.subtracting(finished.applied)
        // The options apply with the pass's first step, the status, which is
        // what they change: they go again only when it applied nothing.
        var options: RefreshOptions = finished.applied.isEmpty ? finished.options : []
        let handedOn = handOnWaiters(of: finished)
        scope.formUnion(handedOn.scope)
        options.formUnion(handedOn.options)
        if !scope.isEmpty {
            enqueue(scope, options: options, reasons: finished.reasons)
        }
    }

    /// The waiters an invalidated pass would have covered wait for a pass
    /// that starts after now. Returns what they need, to request again.
    private func handOnWaiters(of finished: InFlight) -> (scope: RefreshScope, options: RefreshOptions) {
        var scope: RefreshScope = []
        var options: RefreshOptions = []
        for index in waiters.indices where finished.options.isSuperset(of: waiters[index].options) {
            for partIndex in waiters[index].parts.indices {
                let part = waiters[index].parts[partIndex]
                guard part.after < finished.sequence, finished.scope.isSuperset(of: part.scope) else {
                    continue
                }
                waiters[index].parts[partIndex].after = passCount
                scope.formUnion(part.scope)
                options.formUnion(waiters[index].options)
            }
        }
        return (scope, options)
    }

    /// Resumes the waiters whose parts a pass with `sequence` has now all
    /// covered, having loaded `scope` with `options`.
    private func resumeWaiters(coveredBy scope: RefreshScope, options: RefreshOptions, sequence: Int) {
        var remaining: [Waiter] = []
        for var waiter in waiters {
            if options.isSuperset(of: waiter.options) {
                waiter.parts.removeAll { $0.after < sequence && scope.isSuperset(of: $0.scope) }
            }
            if waiter.parts.isEmpty {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    /// Records that the pass with `sequence` loaded `scope`.
    private func markLoaded(_ scope: RefreshScope, sequence: Int) {
        for component in Self.components(of: scope) {
            loadedSequences[component] = max(loadedSequences[component] ?? 0, sequence)
        }
    }

    /// The components of `scope` (status, refs, remotes, metadata), each on
    /// its own.
    private static func components(of scope: RefreshScope) -> [RefreshScope] {
        (0..<RefreshScope.RawValue.bitWidth)
            .map { RefreshScope(rawValue: RefreshScope.RawValue(1) << $0) }
            .filter { scope.contains($0) }
    }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else {
            return
        }
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}
