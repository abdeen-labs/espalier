// The window's presenter. Intents throw typed confirmations, decisions, and
// errors, and this turns them into UI the same way everywhere.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "presenter")

/// The answers an intent has been given so far.
nonisolated public struct IntentAnswers: Sendable, Equatable {
    /// The confirmations the user gave.
    public var confirmed: Set<ConfirmationKind> = []
    /// The decision's answer: what to do with uncommitted changes.
    public var strategy: UncommittedChangesStrategy?
    /// "Also move the folder to the Trash" (`removeRepository`).
    public var moveToTrash = false
    /// "Delete it on the remote too" (`deleteBranch`).
    public var includeRemoteBranch = false

    public init() {}
}

/// A confirmation waiting for the user.
nonisolated public struct PendingConfirmation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let confirmation: Confirmation

    public init(id: UUID = UUID(), confirmation: Confirmation) {
        self.id = id
        self.confirmation = confirmation
    }
}

/// The user's answer to a confirmation.
nonisolated public struct ConfirmationResponse: Sendable, Equatable {
    public var isConfirmed: Bool
    /// "Do not show this message again" was on.
    public var suppressesFutureConfirmations: Bool
    /// The compact sheets' checkbox: "Also move the folder to the Trash",
    /// or "Delete it on the remote too".
    public var isOptionSelected: Bool

    public init(isConfirmed: Bool, suppressesFutureConfirmations: Bool = false, isOptionSelected: Bool = false) {
        self.isConfirmed = isConfirmed
        self.suppressesFutureConfirmations = suppressesFutureConfirmations
        self.isOptionSelected = isOptionSelected
    }

    public static let cancelled = ConfirmationResponse(isConfirmed: false)
}

/// A decision waiting for the user.
nonisolated public struct PendingDecision: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let decision: Decision

    public init(id: UUID = UUID(), decision: Decision) {
        self.id = id
        self.decision = decision
    }
}

/// An error being shown.
nonisolated public struct PresentedError: Sendable, Identifiable {
    public let id: UUID
    public let error: OperationError

    public init(id: UUID = UUID(), error: OperationError) {
        self.id = id
        self.error = error
    }
}

/// Turns the state layer's confirmations, decisions, errors, and outcomes
/// into UI, for one window.
///
/// Views run every intent through `perform(_:outcome:)`. Its state
/// (`confirmation`, `decision`, `error`, `toasts`) is shown by the hosts the
/// shell attaches to the window; tests answer it directly.
@MainActor @Observable
public final class WindowPresenter {
    /// The confirmation showing, if any; others wait in order.
    public var confirmation: PendingConfirmation? { confirmations.first }
    /// The decision showing, if any.
    public var decision: PendingDecision? { decisions.first }
    /// The error showing, if any.
    public var error: PresentedError? { errors.first }
    /// The toasts showing, oldest first.
    public private(set) var toasts: [Toast] = []

    private var confirmations: [PendingConfirmation] = []
    private var decisions: [PendingDecision] = []
    private var errors: [PresentedError] = []
    @ObservationIgnored private var confirmationWaiters: [UUID: CheckedContinuation<ConfirmationResponse, Never>] = [:]
    @ObservationIgnored private var decisionWaiters: [UUID: CheckedContinuation<DecisionAnswer?, Never>] = [:]

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored weak var actions: WindowActions?
    /// The window's undo manager, which the shell sets: while a toast with
    /// Undo shows, its Undo is registered there, so Edit ▸ Undo (⌘Z) runs
    /// it and the toast shows the key.
    @ObservationIgnored public weak var undoManager: UndoManager?
    /// The toasts' registrations with `undoManager`, by toast.
    @ObservationIgnored private var toastUndoTargets: [Toast.ID: ToastUndoTarget] = [:]
    /// Reports what an operation a recovery ran again did, as the window
    /// reports its first run (the window's context sets it).
    @ObservationIgnored var reportOutcome: (@MainActor (OperationOutcome) -> Void)?

    public init(app: AppModel? = nil, actions: WindowActions? = nil) {
        self.app = app
        self.actions = actions
    }

    /// Whether a confirmation, decision, or error is showing.
    public var isPresentingModal: Bool {
        confirmation != nil || decision != nil || error != nil
    }

    // MARK: Performing intents

    /// Runs `intent`, asking for confirmations and decisions until it
    /// succeeds, is cancelled, or fails. Errors are shown; a busy repository
    /// shows a toast. Returns nil when the user cancelled or it failed.
    ///
    /// - Parameters:
    ///   - intent: Calls the model with the answers given so far.
    ///   - outcome: The toast for the result, if any.
    @discardableResult
    public func perform<T: Sendable>(
        _ intent: @escaping @MainActor (IntentAnswers) async throws(OperationError) -> T,
        outcome: (@MainActor (T) -> Toast?)? = nil
    ) async -> T? {
        do {
            let value = try await performThrowing(intent)
            if let value, let outcome, let toast = outcome(value) {
                show(toast)
            }
            return value
        } catch {
            present(error)
            return nil
        }
    }

    /// Runs `intent`, asking for confirmations and decisions, and throws its
    /// other errors to the caller instead of showing them (AI requests show
    /// their errors inline). Returns nil when the user cancelled, the
    /// operation was cancelled, or the repository was busy (a toast says so).
    public func performThrowing<T: Sendable>(
        _ intent: @escaping @MainActor (IntentAnswers) async throws(OperationError) -> T
    ) async throws(OperationError) -> T? {
        var answers = IntentAnswers()
        var hasChosenEditor = false
        while true {
            do throws(OperationError) {
                return try await intent(answers)
            } catch {
                switch error.reason {
                case .confirmationRequired(let confirmation):
                    guard !answers.confirmed.contains(confirmation.kind) else {
                        // The intent asked again for what it was given: a bug,
                        // shown rather than looped on.
                        logger.error("An intent asked again for the confirmation \(confirmation.kind.rawValue, privacy: .public)")
                        throw error
                    }
                    let response = await ask(confirmation)
                    guard response.isConfirmed else {
                        return nil
                    }
                    if response.suppressesFutureConfirmations {
                        suppress(confirmation)
                    }
                    answers.confirmed.insert(confirmation.kind)
                    switch confirmation.kind {
                    case .removeRepository: answers.moveToTrash = response.isOptionSelected
                    case .deleteBranch: answers.includeRemoteBranch = response.isOptionSelected
                    default: break
                    }

                case .decisionRequired(let decision):
                    let isAnswered = switch decision {
                    case .uncommittedChanges: answers.strategy != nil
                    case .externalEditor: hasChosenEditor
                    }
                    guard !isAnswered else {
                        logger.error("An intent asked again for a decision it was given")
                        throw error
                    }
                    switch await decide(decision) {
                    case nil:
                        return nil
                    case .strategy(let strategy):
                        answers.strategy = strategy
                        // A choice that warned confirms what it warned about.
                        answers.confirmed.formUnion(decision.confirmations(answeredBy: strategy))
                    case .editor(let name):
                        // The editor chosen is saved; the intent finds it.
                        hasChosenEditor = true
                        app?.integrations.selectEditor(name)
                    }

                case .cancelled:
                    return nil

                case .busy:
                    show(.busy)
                    return nil

                default:
                    throw error
                }
            }
        }
    }

    // MARK: Confirmations

    /// Shows `confirmation` (after any already waiting) and waits for the
    /// answer.
    public func ask(_ confirmation: Confirmation) async -> ConfirmationResponse {
        let pending = PendingConfirmation(confirmation: confirmation)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfirmationResponse, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                confirmationWaiters[pending.id] = continuation
                confirmations.append(pending)
            }
        } onCancel: {
            Task { @MainActor in
                self.respond(to: pending.id, with: .cancelled)
            }
        }
    }

    /// Answers the confirmation `id`.
    public func respond(to id: PendingConfirmation.ID, with response: ConfirmationResponse) {
        confirmations.removeAll { $0.id == id }
        confirmationWaiters.removeValue(forKey: id)?.resume(returning: response)
    }

    /// Writes the setting a confirmation's "Do not show this message again"
    /// turns off.
    func suppress(_ confirmation: Confirmation) {
        guard let keyPath = confirmation.suppressionSetting, let preferences = app?.preferences else {
            return
        }
        preferences[keyPath: keyPath] = false
    }

    // MARK: Decisions

    /// Shows `decision` and waits for the answer (nil: cancelled).
    public func decide(_ decision: Decision) async -> DecisionAnswer? {
        let pending = PendingDecision(decision: decision)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DecisionAnswer?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                decisionWaiters[pending.id] = continuation
                decisions.append(pending)
            }
        } onCancel: {
            Task { @MainActor in
                self.respond(to: pending.id, with: nil)
            }
        }
    }

    /// Answers the decision `id` (nil: cancelled).
    public func respond(to id: PendingDecision.ID, with answer: DecisionAnswer?) {
        decisions.removeAll { $0.id == id }
        decisionWaiters.removeValue(forKey: id)?.resume(returning: answer)
    }

    // MARK: Errors

    /// Shows an error. Cancellations show nothing, a busy repository a
    /// toast; missing and unsafe repositories show their view instead of an
    /// alert; background failures never reach here.
    public func present(_ error: OperationError) {
        switch error.reason {
        case .cancelled, .missingRepository, .unsafeRepository:
            return
        case .busy:
            show(.busy)
            return
        default:
            break
        }
        guard !error.isBackgroundTask else {
            return
        }
        errors.append(PresentedError(error: error))
    }

    /// Closes the error `id`.
    public func dismissError(_ id: PresentedError.ID) {
        errors.removeAll { $0.id == id }
    }

    /// Closes the error `id` and runs one of its recoveries: headless ones
    /// through `perform`, the others through the window's actions (sign in,
    /// fork, push protection, Settings).
    public func recover(_ id: PresentedError.ID, with recovery: Recovery) async {
        dismissError(id)
        await run(recovery)
    }

    /// Runs a recovery. An operation it runs again reports its outcome as
    /// its first run does (`reportOutcome`).
    public func run(_ recovery: Recovery) async {
        switch recovery {
        case .openSettings(let pane):
            actions?.perform(.openSettings(pane))
        case .signIn(let endpoint, let then):
            actions?.perform(.signIn(endpoint: endpoint, then: then))
        case .createFork(let repositoryID):
            actions?.perform(.createFork(repositoryID: repositoryID))
        case .reviewPushProtection(let repositoryID, let secrets):
            actions?.perform(.reviewPushProtection(repositoryID: repositoryID, secrets: secrets))
        case .stashChangesAndRetry(_, let operation):
            guard let app else {
                return
            }
            // Two steps, each asking its own questions: the changes are
            // stashed once, and the operation runs again with the answers
            // it asks for (a force push warning), not stashing again.
            let stashed = await perform { answers throws(OperationError) in
                try await recovery.stashChanges(in: app, confirmed: answers.confirmed)
            }
            guard stashed == true else {
                return
            }
            let outcome = await perform { answers throws(OperationError) in
                try await operation.perform(in: app, confirmed: answers.confirmed)
            }
            report(outcome)
        case .clearLeftoverRebaseAndRetry(_, let operation):
            guard let app else {
                return
            }
            // Two steps, as above: the rebase's state is cleared once, and
            // the operation runs again with the answers it asks for.
            let cleared: Void? = await perform { _ throws(OperationError) in
                try await recovery.clearLeftoverRebase(in: app)
            }
            guard cleared != nil else {
                return
            }
            let outcome = await perform { answers throws(OperationError) in
                try await operation.perform(in: app, confirmed: answers.confirmed)
            }
            report(outcome)
        case .retry, .fetch, .discardPermanently, .updateLFSFilters, .editGlobalGitConfig, .downloadSuggestedEditor,
             .requestOrganizationAccess:
            guard let app else {
                return
            }
            let outcome = await perform { answers throws(OperationError) in
                try await recovery.perform(in: app, confirmed: answers.confirmed)
            }
            report(outcome)
        }
    }

    /// Reports what an operation run again did, when it ran.
    func report(_ outcome: OperationOutcome?) {
        if let outcome {
            reportOutcome?(outcome)
        }
    }

    // MARK: Toasts

    /// Shows a toast and announces it to VoiceOver. A toast with Undo
    /// registers it with the window's undo manager while it shows.
    public func show(_ toast: Toast) {
        toasts.append(toast)
        registerUndo(for: toast)
        ToastAnnouncer.announce(toast.message)
    }

    /// Closes the toast `id`.
    public func dismissToast(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
        unregisterUndo(for: id)
    }

    /// Whether a toast's Undo also runs from Edit ▸ Undo (⌘Z): the window
    /// has an undo manager to register it with.
    public var undoesToastsByKey: Bool {
        undoManager != nil
    }

    /// The key that runs a toast's Undo, as its key cap shows it.
    public static let toastUndoKey = "⌘Z"

    /// Registers `toast`'s Undo with the window's undo manager: Edit ▸ Undo
    /// runs it as the button does, once.
    private func registerUndo(for toast: Toast) {
        guard toast.undo != nil, let undoManager, toastUndoTargets[toast.id] == nil else {
            return
        }
        let target = ToastUndoTarget(id: toast.id)
        toastUndoTargets[toast.id] = target
        undoManager.registerUndo(withTarget: target) { [weak self] target in
            self?.undoByKey(target.id)
        }
    }

    /// Takes the registration of the toast `id` off the undo manager.
    private func unregisterUndo(for id: Toast.ID) {
        guard let target = toastUndoTargets.removeValue(forKey: id) else {
            return
        }
        undoManager?.removeAllActions(withTarget: target)
    }

    /// Edit ▸ Undo on the toast `id`.
    private func undoByKey(_ id: Toast.ID) {
        if let action = takeToastUndo(id) {
            Task { await action.perform() }
        }
    }

    /// Undo on the toast `id`: closes it and returns its action, or nil
    /// when it has none or has already closed. A toast stays on screen
    /// while it leaves, so a second click on its Undo runs nothing.
    public func takeToastUndo(_ id: Toast.ID) -> ToastAction? {
        guard let toast = toasts.first(where: { $0.id == id }) else {
            return nil
        }
        dismissToast(id)
        return toast.undo
    }

    /// Replaces the toast with `toast`'s ID, if it's still showing, without
    /// announcing it again: an outcome whose Undo is no longer valid keeps
    /// its message without the button.
    public func replaceToast(_ toast: Toast) {
        guard let index = toasts.firstIndex(where: { $0.id == toast.id }) else {
            return
        }
        toasts[index] = toast
        if toast.undo == nil {
            unregisterUndo(for: toast.id)
        } else {
            registerUndo(for: toast)
        }
    }
}

/// What a toast's Undo is registered with the undo manager as: one per
/// toast, so closing the toast takes its registration away.
final class ToastUndoTarget {
    let id: Toast.ID

    init(id: Toast.ID) {
        self.id = id
    }
}

extension Confirmation {
    /// The setting this confirmation's "Do not show this message again"
    /// turns off, when it offers the toggle: its kind's, except for
    /// discarding several files, which asks whatever the setting says (so
    /// the checkbox would have no effect).
    @MainActor
    public var suppressionSetting: ReferenceWritableKeyPath<Preferences, Bool>? {
        if kind == .discardChanges, case .files(let paths) = details, paths.count > 1 {
            return nil
        }
        return kind.suppressionSetting
    }
}

extension ConfirmationKind {
    /// The setting "Do not show this message again" turns off, for the
    /// confirmations that offer it.
    @MainActor
    public var suppressionSetting: ReferenceWritableKeyPath<Preferences, Bool>? {
        switch self {
        case .discardChanges, .discardLines: \.confirmDiscardChanges
        case .discardStash: \.confirmDiscardStash
        case .checkoutCommit: \.confirmCheckoutCommit
        case .forcePush, .rewritePublishedCommits: \.confirmForcePush
        case .undoCommitWithChanges: \.confirmUndoCommit
        case .commitFilteredChanges: \.confirmCommitFilteredChanges
        case .overwriteCommitMessage: \.confirmCommitMessageOverride
        case .removeWorktree: \.confirmWorktreeRemoval
        // Removing a repository (Settings ▸ Prompts only), discarding all
        // changes (always asks), and the rest offer no toggle.
        default: nil
        }
    }
}
