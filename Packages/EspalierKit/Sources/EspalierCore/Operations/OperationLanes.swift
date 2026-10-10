/// The exclusion lanes an operation holds.
///
/// - `local`: anything that writes the index, the working tree, HEAD, or
///   local refs. One per working tree.
/// - `network`: fetch, pull, push, publish, remote branch deletion. Shared
///   by every worktree of a repository (the same git common directory), so
///   a worktree's fetch can't race its main repository's on
///   `refs/remotes`.
///
/// Pull takes both. Lanes are always acquired network first, then local.
public struct OperationLanes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let local = OperationLanes(rawValue: 1 << 0)
    public static let network = OperationLanes(rawValue: 1 << 1)
}

/// What happens when an operation finds a lane taken.
public enum BusyPolicy: Sendable, Hashable {
    /// The user started it: it waits behind background work and fails with
    /// `busy` behind another user operation (the UI disables controls; this
    /// is the safety net).
    case user
    /// Background work started it: it skips when the lane is taken.
    case background
}

/// One exclusion lane.
@MainActor
final class OperationLane {
    /// What acquiring a lane came to.
    enum AcquireResult: Equatable {
        /// The operation holds the lane.
        case acquired
        /// A background operation found the lane taken and doesn't run.
        case skipped
        /// A user operation found the lane taken by the user (the kind of
        /// the operation holding it or waiting for it).
        case busy(OperationKind)
        /// The waiting task was cancelled before the lane came free.
        case cancelled
    }

    private struct Waiter {
        let operation: ActiveOperation
        let continuation: CheckedContinuation<AcquireResult, Never>
    }

    /// A name for logs ("local", "network").
    let name: String

    /// The operation holding the lane.
    private(set) var holder: ActiveOperation?

    /// User operations waiting for a background holder to finish, in order.
    private var waiters: [Waiter] = []

    init(name: String) {
        self.name = name
    }

    /// Whether nothing holds the lane or waits for it.
    var isFree: Bool {
        holder == nil && waiters.isEmpty
    }

    /// Takes the lane for `operation`, waiting behind a background holder
    /// when `policy` is `.user`.
    func acquire(for operation: ActiveOperation, policy: BusyPolicy) async -> AcquireResult {
        if isFree {
            holder = operation
            return .acquired
        }
        if policy == .background {
            return .skipped
        }
        if let holder, !holder.isBackgroundTask {
            return .busy(holder.kind)
        }
        if let waiter = waiters.first {
            return .busy(waiter.operation.kind)
        }

        let id = operation.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AcquireResult, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                waiters.append(Waiter(operation: operation, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(id)
            }
        }
    }

    /// Releases the lane `operation` holds, handing it to the next waiter.
    func release(_ operation: ActiveOperation) {
        guard holder?.id == operation.id else {
            return
        }
        if waiters.isEmpty {
            holder = nil
        } else {
            let next = waiters.removeFirst()
            holder = next.operation
            next.continuation.resume(returning: .acquired)
        }
    }

    private func cancelWaiter(_ id: ActiveOperation.ID) {
        guard let index = waiters.firstIndex(where: { $0.operation.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: .cancelled)
    }
}

/// The network lanes, one per git common directory, shared by the
/// repositories (worktrees) that have it.
@MainActor
final class NetworkLaneRegistry {
    private var lanes: [String: OperationLane] = [:]

    init() {}

    /// The lane for `key`: a repository's common directory, or its ID until
    /// the first refresh resolves the directory.
    func lane(for key: String) -> OperationLane {
        if let lane = lanes[key] {
            return lane
        }
        let lane = OperationLane(name: "network")
        lanes[key] = lane
        return lane
    }

    /// Forgets free lanes no repository uses any more.
    func prune(keeping keys: Set<String>) {
        lanes = lanes.filter { keys.contains($0.key) || !$0.value.isFree }
    }
}
