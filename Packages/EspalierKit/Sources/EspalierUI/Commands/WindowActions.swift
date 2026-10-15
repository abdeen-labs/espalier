// The window's action router: every feature registers handlers for the
// action kinds it owns, and menus, toolbars, context menus, and other
// features call them without importing each other's views.

import EspalierCore
import GitKit
import Observation

/// Routes actions to the features that handle them, for one window.
///
/// Each feature's `*Actions.swift` registers its handlers in
/// `register(into:context:)`, which the shell calls once per window. An
/// action can run when a handler is registered, the handler says it's
/// enabled, the repository's state allows it (`CommandAvailability`, from
/// `RepositoryCapabilities`), and, for repository-scoped actions, no
/// confirmation, decision, error, or prompt is showing.
@MainActor @Observable
public final class WindowActions {
    /// A feature's handler for one action kind.
    public struct Handler {
        /// Whether the action can run now. Read model state here: menus
        /// observe it.
        public var isEnabled: @MainActor (ActionID) -> Bool
        /// Whether the menu item shows a check mark (toggles and choices).
        public var isChecked: (@MainActor (ActionID) -> Bool)?
        /// The menu title, when it depends on the state.
        public var title: (@MainActor (ActionID) -> String?)?
        /// Whether the menu item is left out, with its shortcut (a feature
        /// turned off, such as AI).
        public var isHidden: (@MainActor (ActionID) -> Bool)?
        /// Runs the action.
        public var perform: @MainActor (ActionID) async -> Void

        public init(
            isEnabled: @escaping @MainActor (ActionID) -> Bool = { _ in true },
            isChecked: (@MainActor (ActionID) -> Bool)? = nil,
            title: (@MainActor (ActionID) -> String?)? = nil,
            isHidden: (@MainActor (ActionID) -> Bool)? = nil,
            perform: @escaping @MainActor (ActionID) async -> Void
        ) {
            self.isEnabled = isEnabled
            self.isChecked = isChecked
            self.title = title
            self.isHidden = isHidden
            self.perform = perform
        }
    }

    @ObservationIgnored private var handlers: [ActionKind: Handler] = [:]
    @ObservationIgnored private var running: [ActionKind: Task<Void, Never>] = [:]

    /// Window-level rules: whether the repository's state allows an action
    /// (`CommandAvailability`).
    @ObservationIgnored var availability: (@MainActor (ActionKind) -> Bool)?
    /// Window-level titles that depend on the state ("Force Push…",
    /// "Remove…").
    @ObservationIgnored var stateTitle: (@MainActor (ActionID) -> String?)?
    /// Whether a confirmation, decision, error, or prompt is showing.
    @ObservationIgnored var isModalPresented: (@MainActor () -> Bool)?

    public init() {}

    // MARK: Registering

    /// Registers the handler for `kind`, replacing any earlier one (a
    /// feature's handler replaces the shell's stub).
    public func register(_ kind: ActionKind, _ handler: Handler) {
        handlers[kind] = handler
    }

    /// Registers a handler built from closures.
    public func register(
        _ kind: ActionKind,
        isEnabled: @escaping @MainActor (ActionID) -> Bool = { _ in true },
        isChecked: (@MainActor (ActionID) -> Bool)? = nil,
        title: (@MainActor (ActionID) -> String?)? = nil,
        isHidden: (@MainActor (ActionID) -> Bool)? = nil,
        perform: @escaping @MainActor (ActionID) async -> Void
    ) {
        register(kind, Handler(isEnabled: isEnabled, isChecked: isChecked, title: title, isHidden: isHidden, perform: perform))
    }

    // MARK: Validating

    /// Whether `action` can run now.
    public func canPerform(_ action: ActionID) -> Bool {
        let kind = action.kind
        guard let handler = handlers[kind] else {
            return false
        }
        if handler.isHidden?(action) == true {
            return false
        }
        if kind.isRepositoryScoped, isModalPresented?() == true {
            return false
        }
        if let availability, !availability(kind) {
            return false
        }
        return handler.isEnabled(action)
    }

    /// Whether `action`'s menu item shows a check mark.
    public func isChecked(_ action: ActionID) -> Bool {
        handlers[action.kind]?.isChecked?(action) ?? false
    }

    /// Whether `action`'s menu item is left out (its handler hides it).
    public func isHidden(_ action: ActionID) -> Bool {
        handlers[action.kind]?.isHidden?(action) ?? false
    }

    /// `action`'s menu title now.
    public func title(for action: ActionID) -> String {
        if let title = handlers[action.kind]?.title?(action) {
            return title
        }
        if let title = stateTitle?(action) {
            return title
        }
        return action.defaultTitle
    }

    // MARK: Performing

    /// Runs `action` if it can run. Returns at once; the handler runs in a
    /// task.
    public func perform(_ action: ActionID) {
        guard canPerform(action) else {
            return
        }
        let kind = action.kind
        let task = Task { [weak self] in
            guard let handler = self?.handlers[kind] else {
                return
            }
            await handler.perform(action)
        }
        running[kind] = task
    }

    /// Runs `action` if it can run, and waits for its handler.
    public func performAndWait(_ action: ActionID) async {
        guard canPerform(action), let handler = handlers[action.kind] else {
            return
        }
        await handler.perform(action)
    }

    /// Waits for the handlers started by `perform(_:)` (for tests).
    public func idle() async {
        while let (kind, task) = running.first {
            await task.value
            if running[kind] == task {
                running[kind] = nil
            }
        }
    }
}
