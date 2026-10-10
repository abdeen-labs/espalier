// Ported from desktop/app/src/lib/stores/ahead-behind-store.ts

import EspalierSupport
import GitKit

/// The maximum number of comparisons kept.
let aheadBehindCacheSize = 2500

/// Caches how far one commit is ahead of and behind another
/// (`git rev-list --left-right --count from...to`), for branch lists that
/// compare every branch with the current one.
///
/// At most one calculation runs at a time, the least recently used results
/// are evicted, and a failed calculation isn't retried until refs change.
/// Keys are commit IDs, so results never go stale.
@MainActor
final class AheadBehindCache {
    private struct Key: Hashable {
        let from: ExactString
        let to: ExactString
    }

    private struct Entry {
        /// Nil when the calculation failed.
        var value: AheadBehind?
        var lastUse: UInt64
    }

    private let maxSize: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let gate = SerialGate()

    init(maxSize: Int = aheadBehindCacheSize) {
        self.maxSize = maxSize
    }

    /// How many comparisons are cached (for tests).
    var count: Int {
        entries.count
    }

    /// The cached result for the range, without calculating it: nil when it
    /// isn't cached or failed.
    func cached(from: String, to: String) -> AheadBehind? {
        lookup(Key(from: ExactString(from), to: ExactString(to))) ?? nil
    }

    /// The result for the range, calculated with `compute` unless it's cached.
    /// Calculations wait their turn; a task cancelled while waiting gets nil
    /// without running git, and a task cancelled while git runs gets nil while
    /// the result is still cached.
    ///
    /// - Returns: Nil when cancelled or when the calculation failed (now or
    ///   before).
    func aheadBehind(from: String, to: String, compute: @escaping @Sendable () async -> AheadBehind?) async -> AheadBehind? {
        let key = Key(from: ExactString(from), to: ExactString(to))
        if let cached = lookup(key) {
            return cached
        }

        guard await gate.acquire() else {
            return nil
        }
        // The caller has either aborted or the range was calculated while
        // this one waited.
        if Task.isCancelled {
            gate.release()
            return nil
        }
        if let cached = lookup(key) {
            gate.release()
            return cached
        }

        // A task of its own, so a caller's cancellation doesn't stop git and
        // record a failure.
        let value = await Task { await compute() }.value
        store(value, for: key)
        gate.release()
        return Task.isCancelled ? nil : value
    }

    /// Forgets failed calculations, so they run again (refs changed).
    func forgetFailures() {
        entries = entries.filter { $0.value.value != nil }
    }

    /// Forgets everything.
    func removeAll() {
        entries.removeAll()
    }

    /// The cached result: `.some(nil)` for a failure, nil when not cached.
    private func lookup(_ key: Key) -> AheadBehind?? {
        guard var entry = entries[key] else {
            return nil
        }
        clock &+= 1
        entry.lastUse = clock
        entries[key] = entry
        return .some(entry.value)
    }

    private func store(_ value: AheadBehind?, for key: Key) {
        clock &+= 1
        entries[key] = Entry(value: value, lastUse: clock)
        guard entries.count > maxSize else {
            return
        }
        if let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
        }
    }
}

/// Lets one task at a time through, in order; a task cancelled while it
/// waits leaves the queue.
@MainActor
private final class SerialGate {
    private var isHeld = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID: UInt64 = 0

    /// Waits for the gate. Returns false, without the gate, when the task is
    /// cancelled while waiting.
    func acquire() async -> Bool {
        if !isHeld {
            isHeld = true
            return true
        }
        let id = nextID
        nextID &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(id)
            }
        }
    }

    /// Passes the gate to the next waiter, or opens it.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

extension BranchesModel {
    /// How far `to` is ahead of and behind `from`, if it's cached: `ahead`
    /// counts the commits only `from` has, `behind` those only `to` has. Pass
    /// commit IDs, which never go stale.
    public func cachedAheadBehind(from: String, to: String) -> AheadBehind? {
        aheadBehindCache.cached(from: from, to: to)
    }

    /// How far `to` is ahead of and behind `from`, calculated one comparison at
    /// a time and cached. A cancelled task (a row scrolled away) gets nil
    /// without waiting for git. Nil when the comparison fails, which isn't
    /// retried until refs change.
    public func aheadBehind(from: String, to: String) async -> AheadBehind? {
        guard let repository else {
            return nil
        }
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        return await aheadBehindCache.aheadBehind(from: from, to: to) {
            let result: AheadBehind?? = await environment.withRuntimes {
                try? await getAheadBehind(gitRepository, revSymmetricDifference(from, to))
            }
            return result ?? nil
        }
    }
}
