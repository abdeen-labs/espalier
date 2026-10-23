// The call to action on a branch's Ahead, the one place a merge, a squash
// and merge, or a rebase between the current branch and another starts: the
// status line saying what the method would do (`CompareModel.statusMessage`)
// with its symbol, and the method's split button, whose menu switches the
// method. The Branch menu's commands, their shortcuts, the branch rows'
// menus, and the branch popover's merge all lead here (BranchActions).

import EspalierCore
import GitKit
import SwiftUI

/// The status line's symbol: the arc while git checks, then what it found.
nonisolated enum MergeStatus: Sendable, Equatable {
    case loading, clean, conflicts, invalid
    /// Git couldn't check: a question mark.
    case unknown
}

/// What the call to action shows.
nonisolated struct MergeCallToActionContent: Sendable, Equatable {
    var method: CompareMethod
    /// The status line's symbol.
    var status: MergeStatus?
    /// What the method would do.
    var message: String?
    var canStart: Bool

    init(method: CompareMethod, status: MergeStatus?, message: String?, canStart: Bool) {
        self.method = method
        self.status = status
        self.message = message
        self.canStart = canStart
    }

    @MainActor
    init(comparison: CompareModel) {
        let message = comparison.statusMessage
        let status: MergeStatus? = switch comparison.computedAction {
        case .loading?: .loading
        case .clean?: .clean
        case .conflicts?: .conflicts
        case .invalid?: .invalid
        case nil: comparison.isMergeCheckFailed ? .unknown : nil
        }
        self.init(method: comparison.method, status: message == nil ? nil : status, message: message, canStart: comparison.canStart)
    }
}

/// What the call to action's controls do.
struct MergeCallToActionActions {
    var setMethod: (CompareMethod) -> Void = { _ in }
    var start: () -> Void = {}
}

/// The status line and the method's split button, prominent as the place's
/// one action.
struct MergeCallToAction: View {
    let content: MergeCallToActionContent
    var actions = MergeCallToActionActions()

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.insetMedium) {
            MergeStatusLine(status: content.status, message: content.message)
            MergeMethodButton(
                method: Binding(get: { content.method }, set: { actions.setMethod($0) }),
                canStart: content.canStart,
                start: actions.start
            )
        }
    }
}

/// The status line: its symbol and message.
struct MergeStatusLine: View {
    let status: MergeStatus?
    let message: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            if let status {
                MergeStatusIcon(status: status)
                    .frame(width: Metrics.symbolWidth)
            }
            Text(message ?? " ")
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status line's symbol: the arc while checking, then a check, a
/// warning, a cross, or a question mark.
struct MergeStatusIcon: View {
    let status: MergeStatus

    var body: some View {
        switch status {
        case .loading:
            // The arc's center on the middle of the line's cap height,
            // where the symbols' centers sit.
            let offset = AppKitTypography.secondary.capHeight / 2
            ArcProgress(.mini)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + offset
                }
                .accessibilityLabel("Checking")
        case .clean:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityLabel("Ready")
        case .conflicts:
            WarningGlyph()
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityLabel("Unavailable")
        case .unknown:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.text3)
                .accessibilityLabel("Unknown")
        }
    }
}

/// The method's split button: its main part starts the method; its menu
/// switches the method, each with its description, the current one
/// checked. While the method can't start, the whole button opens the menu,
/// so the method can still be switched. The tooltip is the method's
/// description.
struct MergeMethodButton: View {
    @Binding var method: CompareMethod
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        if canStart {
            SplitCapsuleButton(.prominent, menuLabel: "Merge Options", action: start) {
                Text(method.label)
            } menu: {
                options
            }
            .fixedSize()
            .tooltip(method.description)
        } else {
            PullDownButton("Merge Options", value: method.label) {
                options
            } label: {
                MenuCapsuleLabel(method.label)
            }
            .buttonStyle(.quiet)
            .fixedSize()
            .tooltip(method.description)
        }
    }

    /// The methods, each with its description, the current one checked.
    private var options: MenuContent {
        MenuContent {
            MenuPicker(selection: $method) {
                for option in CompareMethod.allCases {
                    MenuChoice(option.label, value: option, subtitle: option.description)
                }
            }
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
