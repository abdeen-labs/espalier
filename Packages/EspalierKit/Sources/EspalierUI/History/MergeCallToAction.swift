// Compare's call to action: a status line saying what merging, squash
// merging, or rebasing would do (`CompareModel.statusMessage`), and a split
// button whose menu picks the method.

import EspalierCore
import GitKit
import SwiftUI

/// What the call to action shows.
nonisolated struct MergeCallToActionContent: Sendable, Equatable {
    /// The status line's symbol.
    enum Status: Sendable, Equatable {
        case loading, clean, conflicts, invalid
    }

    var method: CompareMethod
    var status: Status?
    /// What the method would do.
    var message: String?
    var canStart: Bool

    init(method: CompareMethod, status: Status?, message: String?, canStart: Bool) {
        self.method = method
        self.status = status
        self.message = message
        self.canStart = canStart
    }

    @MainActor
    init(comparison: CompareModel) {
        let message = comparison.statusMessage
        let status: Status? = switch comparison.computedAction {
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

/// The status line and the split button.
struct MergeCallToAction: View {
    let content: MergeCallToActionContent
    var actions = MergeCallToActionActions()

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.insetMedium) {
            if let message = content.message {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.grid + 2) {
                    statusSymbol
                    Text(message)
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            methodButton
                .fixedSize()
                .help(content.method.description)
        }
    }

    /// The split button: its main part starts the method, its chevron
    /// switches it; prominent, as Compare's one action. While the method
    /// can't start, the whole button is a quiet pull-down, so the method
    /// can still be switched.
    @ViewBuilder
    private var methodButton: some View {
        if content.canStart {
            SplitCapsuleButton(.prominent, menuLabel: "Merge Method", action: actions.start) {
                Text(content.method.label)
            } menu: {
                methods
            }
        } else {
            Menu {
                methods
            } label: {
                HStack(spacing: 6) {
                    Text(content.method.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.text3)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .menuIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var methods: some View {
        ForEach(CompareMethod.allCases, id: \.self) { method in
            Button {
                actions.setMethod(method)
            } label: {
                Text(method.label)
                Text(method.description)
            }
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch content.status {
        case .loading?:
            ArcProgress(.mini)
        case .clean?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityLabel("Ready")
        case .conflicts?:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(espalier: Palette.warning))
                .accessibilityLabel("Conflicts")
        case .invalid?:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityLabel("Unavailable")
        case nil:
            EmptyView()
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
