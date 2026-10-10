// Compare's call to action: the status line saying what merging, squash
// merging, or rebasing would do (`CompareModel.statusMessage`), and the
// method's split button, the Integrate sheet's own (`IntegrateStatusLine`,
// `IntegrateMethodButton`).

import EspalierCore
import GitKit
import SwiftUI

/// What the call to action shows.
nonisolated struct MergeCallToActionContent: Sendable, Equatable {
    var method: CompareMethod
    /// The status line's symbol.
    var status: IntegrateStatus.Icon?
    /// What the method would do.
    var message: String?
    var canStart: Bool

    init(method: CompareMethod, status: IntegrateStatus.Icon?, message: String?, canStart: Bool) {
        self.method = method
        self.status = status
        self.message = message
        self.canStart = canStart
    }

    @MainActor
    init(comparison: CompareModel) {
        let message = comparison.statusMessage
        let status: IntegrateStatus.Icon? = switch comparison.computedAction {
        case .loading?: .loading
        case .clean?: .clean
        case .conflicts?: .conflicts
        case .invalid?: .invalid
        case nil: nil
        }
        self.init(method: comparison.method, status: message == nil ? nil : status, message: message, canStart: comparison.canStart)
    }
}

/// What the call to action's controls do.
struct MergeCallToActionActions {
    var setMethod: (CompareMethod) -> Void = { _ in }
    var start: () -> Void = {}
}

/// The status line and the method's split button, prominent as Compare's
/// one action.
struct MergeCallToAction: View {
    let content: MergeCallToActionContent
    var actions = MergeCallToActionActions()

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.insetMedium) {
            IntegrateStatusLine(status: IntegrateStatus(icon: content.status, message: content.message))
            IntegrateMethodButton(
                method: Binding(get: { content.method }, set: { actions.setMethod($0) }),
                canStart: content.canStart,
                help: nil,
                shortcut: nil,
                start: actions.start
            )
        }
    }
}

/// Starting what the call to action offers.
@MainActor
enum MergeCallToActions {
    /// Merges, squash merges, or rebases onto `branch` through the
    /// presenter, then shows the history.
    static func start(_ method: CompareMethod, with branch: Branch, repository: RepositoryModel, context: WindowContext) async {
        let operations = repository.operations
        let started: Bool
        switch method {
        case .merge, .squashMerge:
            let outcome = await context.presenter.perform { _ throws(OperationError) in
                try await operations.merge(branch, squash: method == .squashMerge)
            } outcome: { outcome in
                outcome.summary.map { Toast($0) }
            }
            started = outcome != nil
        case .rebase:
            let result = await context.presenter.perform { answers throws(OperationError) in
                try await operations.rebase(onto: branch, confirmed: answers.confirmed)
            } outcome: { result in
                result.summary.map { Toast($0) }
            }
            started = result != nil
        }
        if started {
            context.select(.history)
        }
    }
}
