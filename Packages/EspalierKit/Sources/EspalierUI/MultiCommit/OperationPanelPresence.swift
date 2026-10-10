// When the operation panel shows in Changes, by the app's 300 ms rule for
// progress: at once when an operation waits on the user (conflicts, an
// interrupted rebase, a stash restore's conflicts, an operation only git can
// finish), and only once a running operation has run 300 ms, so a fast one
// (a fast-forward merge, a small cherry-pick) never shows the bar or takes
// the composer away. Once shown, the panel stays until nothing's left.

import EspalierCore
import EspalierSupport
import Foundation
import SwiftUI

/// Whether the operation panel shows, with the 300 ms rule.
@MainActor @Observable
final class OperationPanelPresence {
    /// What the repository's state asks of the panel.
    enum Demand: Equatable {
        /// Nothing runs or waits: no panel.
        case none
        /// Something waits on the user: the panel at once.
        case now
        /// An operation runs: the panel once it has run 300 ms.
        case afterDelay
    }

    /// Whether a running operation has run long enough to show.
    private(set) var hasWaited = false
    @ObservationIgnored private var demand: Demand = .none
    @ObservationIgnored private var delay: Task<Void, Never>?

    /// Whether the panel shows for `demand`: at once for what waits on the
    /// user, after the delay for what runs (or at once when delayed
    /// content shows immediately, in snapshots), and stays while an
    /// operation shown waiting runs again (Continue).
    func isShown(for demand: Demand, immediately: Bool = false) -> Bool {
        switch demand {
        case .none: false
        case .now: true
        case .afterDelay: immediately || hasWaited
        }
    }

    /// Follows `demand`: forgets the wait when nothing's left, counts a
    /// panel shown at once as waited, and otherwise starts the delay on
    /// `scheduler`.
    func update(_ demand: Demand, scheduler: any Scheduler, delay duration: Duration = Timing.spinnerDelay) {
        self.demand = demand
        switch demand {
        case .none:
            cancelDelay()
            if hasWaited {
                hasWaited = false
            }
        case .now:
            cancelDelay()
            if !hasWaited {
                hasWaited = true
            }
        case .afterDelay:
            guard !hasWaited, delay == nil else {
                return
            }
            delay = Task { [weak self] in
                try? await scheduler.sleep(for: duration)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.delay = nil
                if self.demand == .afterDelay {
                    self.hasWaited = true
                }
            }
        }
    }

    private func cancelDelay() {
        delay?.cancel()
        delay = nil
    }

    /// What `repository`'s state asks of the panel: the cases of
    /// `OperationPanelContent.make`, read without its file counts.
    static func demand(for repository: RepositoryModel) -> Demand {
        let operations = repository.operations
        if let current = operations.current {
            switch current.phase {
            case .running, .continuing: return .afterDelay
            case .conflicted, .interrupted: return .now
            }
        }
        if operations.conflictState != nil {
            return .now
        }
        if let local = repository.localOperation, OperationPanelContent.runningName(of: local.kind) != nil {
            return .afterDelay
        }
        if repository.stash.conflictedRestore != nil {
            return .now
        }
        if let inProgress = repository.gitState.inProgress, inProgress.unsupportedTitle != nil, inProgress.unsupportedMessage != nil {
            return .now
        }
        return .none
    }
}

extension EnvironmentValues {
    /// Whether Changes shows the operation panel now (the 300 ms rule
    /// applied); nil outside Changes, where the operation's state alone
    /// decides.
    @Entry var showsOperationPanel: Bool? = nil
}
