import Foundation
import GitKit
import Synchronization

/// What an operation's body works with.
///
/// The values are captured when the operation starts, so a body never
/// reads model state that changed while git ran.
@MainActor
public final class OperationContext: Sendable {
    /// The repository as git takes it, when the operation started.
    public nonisolated let repository: Repository
    public nonisolated let kind: OperationKind
    /// Whether background work runs the operation: pass it to GitKit
    /// (`isBackgroundTask`) so git never prompts.
    public nonisolated let isBackgroundTask: Bool
    /// The hook callbacks for operations that intercept hooks.
    public nonisolated let hooks: HookCallbacks
    /// Where to report progress.
    public nonisolated let progress: ProgressSink
    /// The web URL of the repository's GitHub repository, for
    /// `getFallbackUrlForProxyResolve`.
    public nonisolated let gitHubHTMLURL: String?
    /// The repository's main worktree, when it's a linked worktree.
    public nonisolated let mainWorktreePath: String?

    nonisolated init(
        repository: Repository,
        kind: OperationKind,
        isBackgroundTask: Bool,
        hooks: HookCallbacks,
        progress: ProgressSink,
        gitHubHTMLURL: String?,
        mainWorktreePath: String?
    ) {
        self.repository = repository
        self.kind = kind
        self.isBackgroundTask = isBackgroundTask
        self.hooks = hooks
        self.progress = progress
        self.gitHubHTMLURL = gitHubHTMLURL
        self.mainWorktreePath = mainWorktreePath
    }
}

/// The hook callbacks of one operation, for the GitKit calls that
/// intercept hooks.
public struct HookCallbacks: Sendable {
    /// Reports a hook starting, finishing, or failing.
    public let onHookProgress: @Sendable (HookProgress) -> Void
    /// Asks the user whether to abort or ignore a failed hook, recording an
    /// abort. Nil for background operations, whose failing hooks abort
    /// without asking.
    public let onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?
    /// Receives each git process's terminal output subscription.
    public let onTerminalOutputAvailable: TerminalOutputCallback

    let state: HookState

    init(
        onHookProgress: @escaping @Sendable (HookProgress) -> Void,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?,
        onTerminalOutputAvailable: @escaping TerminalOutputCallback,
        state: HookState
    ) {
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
        self.state = state
    }

    /// The hook the user chose to abort after it failed, if any.
    public var abortedHook: String? {
        state.abortedHook
    }

    /// Callbacks that report nothing and abort failing hooks.
    public static var none: HookCallbacks {
        HookCallbacks(onHookProgress: { _ in }, onHookFailure: nil, onTerminalOutputAvailable: { _ in }, state: HookState())
    }
}

/// The hook state of one running operation.
final class HookState: Sendable {
    private struct State {
        var abortedHook: String?
        var runningHook: String?
        var abort: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var abortedHook: String? {
        state.withLock { $0.abortedHook }
    }

    func recordAbort(_ hookName: String) {
        state.withLock { $0.abortedHook = hookName }
    }

    /// Tracks the running hook and its abort function.
    func record(_ progress: HookProgress) {
        state.withLock { state in
            switch progress {
            case .started(let hookName, let abort):
                state.runningHook = hookName
                state.abort = abort
            case .finished, .failed:
                state.runningHook = nil
                state.abort = nil
            }
        }
    }

    /// Aborts the running hook, if any.
    /// Returns whether a hook was running.
    @discardableResult
    func abortRunningHook() -> Bool {
        let abort = state.withLock { state -> (@Sendable () -> Void)? in
            guard let abort = state.abort else { return nil }
            if let running = state.runningHook {
                state.abortedHook = running
            }
            return abort
        }
        abort?()
        return abort != nil
    }
}
