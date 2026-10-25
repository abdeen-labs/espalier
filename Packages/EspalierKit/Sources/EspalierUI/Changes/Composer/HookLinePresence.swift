// When the composer's hook line shows, by the app's 300 ms rule for
// progress: once a hook has run 300 ms, so a quick hook (a post-commit hook
// that logs a line) never flashes the line. A hook that ends sooner shows
// nothing, even while the commit goes on. Once shown, the line follows the
// commit's hooks and stays at least 1 s, past the commit's end if need be,
// on the last hook it showed.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// The composer's hook line as it shows.
nonisolated struct HookLine: Sendable {
    var hook: HookActivity
    /// The commit's terminal output, for Show Output.
    var output: TerminalOutputListener?
}

/// Whether the composer's hook line shows, with the 300 ms rule.
@MainActor @Observable
final class HookLinePresence {
    /// The line, while it shows.
    private(set) var line: HookLine?

    /// The composer's hook now, as the commit reports it.
    @ObservationIgnored private var current: HookLine?
    @ObservationIgnored private var repository: RepositoryID?
    @ObservationIgnored private var delay: Task<Void, Never>?
    /// Runs while the line hasn't shown its minimum.
    @ObservationIgnored private var hold: Task<Void, Never>?

    /// Follows the composer's hook in `repository`: shows a hook once it
    /// has run `delay`, then holds the line at least `minimum`. Another
    /// repository drops the line at once.
    func update(
        _ hook: HookActivity?,
        output: TerminalOutputListener?,
        in repository: RepositoryID,
        scheduler: any Scheduler,
        delay delayDuration: Duration = Timing.spinnerDelay,
        minimum: Duration = Timing.hookLineMinimum
    ) {
        if repository != self.repository {
            self.repository = repository
            cancelDelay()
            hold?.cancel()
            hold = nil
            if line != nil {
                line = nil
            }
        }
        current = hook.map { HookLine(hook: $0, output: output) }
        if line != nil {
            if let current {
                line = current
            } else if hold == nil {
                line = nil
            }
            return
        }
        guard hook?.status == .running else {
            cancelDelay()
            return
        }
        guard delay == nil else {
            return
        }
        delay = Task { [weak self] in
            try? await scheduler.sleep(for: delayDuration)
            guard let self, !Task.isCancelled else {
                return
            }
            self.delay = nil
            if let current = self.current, current.hook.status == .running {
                self.show(current, scheduler: scheduler, minimum: minimum)
            }
        }
    }

    private func show(_ line: HookLine, scheduler: any Scheduler, minimum: Duration) {
        self.line = line
        hold = Task { [weak self] in
            try? await scheduler.sleep(for: minimum)
            guard let self, !Task.isCancelled else {
                return
            }
            self.hold = nil
            if self.current == nil {
                self.line = nil
            }
        }
    }

    private func cancelDelay() {
        delay?.cancel()
        delay = nil
    }

    /// The hook the composer's line is for: the commit's, or a merge's
    /// commit's as the merge continues.
    static func hook(for repository: RepositoryModel) -> HookActivity? {
        guard let operation = repository.localOperation,
              operation.kind == .commit || OperationSlotContent.isContinuing(repository) else {
            return nil
        }
        return operation.hook
    }
}

extension EnvironmentValues {
    /// The composer's hook line, with the 300 ms rule applied.
    @Entry var hookLine: HookLine? = nil
}
