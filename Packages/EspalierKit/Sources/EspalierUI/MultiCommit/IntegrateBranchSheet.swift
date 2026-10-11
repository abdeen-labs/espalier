// Ported in part from desktop/app/src/ui/multi-commit-operation/choose-branch/base-choose-branch-dialog.tsx, merge-choose-branch-dialog.tsx, rebase-choose-branch-dialog.tsx, and ui/lib/update-branch.ts
//
// Merge, Squash and Merge, and Rebase in one sheet whose split button
// switches the method in place: the titles, the branch preselected, the
// status lines (merge-tree's outcome, the commit counts, a rebase's
// preview), when the operation can start, the rebase tooltips, and the three
// methods with their descriptions.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// How a branch comes into the current one: Compare's methods, with their
/// labels and descriptions, which the sheet and Compare's call to action
/// pick with the same button (`IntegrateMethodButton`).
public typealias IntegrateMethod = CompareMethod

extension CompareMethod {
    /// "Merge into main", "Squash and Merge into main", "Rebase main".
    nonisolated public func title(currentBranch: String) -> String {
        // Cut to 40 characters with an ellipsis.
        let name = currentBranch.count <= 40 ? currentBranch : "\(currentBranch.prefix(39))…"
        switch self {
        case .merge: return "Merge into \(name)"
        case .squashMerge: return "Squash and Merge into \(name)"
        case .rebase: return "Rebase \(name)"
        }
    }
}

/// The sheet's status line and whether the method can start.
nonisolated public struct IntegrateStatus: Sendable, Equatable {
    /// The line's symbol.
    public enum Icon: Sendable, Equatable {
        case loading, clean, conflicts, invalid
    }

    public var icon: Icon?
    public var message: String?
    public var canStart: Bool
    /// The button's tooltip when it can't start (rebase).
    public var buttonHelp: String?

    public init(icon: Icon? = nil, message: String? = nil, canStart: Bool = false, buttonHelp: String? = nil) {
        self.icon = icon
        self.message = message
        self.canStart = canStart
        self.buttonHelp = buttonHelp
    }

    /// What merging or squash merging `branch` into `current` would do.
    /// `preview` nil means it's loading.
    public static func merge(current: String, branch: String?, preview: MergePreview?) -> IntegrateStatus {
        guard let branch, !JSCompat.strictEquals(branch, current) else {
            return IntegrateStatus()
        }
        guard let preview else {
            return IntegrateStatus(icon: .loading, message: "Checking whether Git can merge automatically…")
        }
        switch preview.status {
        case .loading:
            return IntegrateStatus(icon: .loading, message: "Checking whether Git can merge automatically…")
        case .clean where preview.commitCount == 0:
            return IntegrateStatus(icon: .clean, message: "\(current) is already up to date with \(branch)")
        case .clean:
            let commits = preview.commitCount == 1 ? "commit" : "commits"
            return IntegrateStatus(
                icon: .clean,
                message: "This will merge \(preview.commitCount) \(commits) from \(branch) into \(current)",
                canStart: true
            )
        case .invalid:
            return IntegrateStatus(icon: .invalid, message: "These branches have unrelated histories and can't be merged")
        case .conflicts(let count):
            let files = count == 1 ? "file" : "files"
            return IntegrateStatus(
                icon: .conflicts,
                message: "There will be \(count) conflicted \(files) when merging \(branch) into \(current)",
                canStart: true
            )
        }
    }

    /// What rebasing `current` onto `base` would do. `preview` nil means
    /// it's loading.
    public static func rebase(current: String, base: String?, preview: RebasePreview?) -> IntegrateStatus {
        guard let base else {
            return IntegrateStatus()
        }
        if JSCompat.strictEquals(base, current) {
            return IntegrateStatus(buttonHelp: "You can't rebase a branch onto itself.")
        }
        let upToDateHelp = "The current branch is already up to date with the selected branch."
        switch preview {
        case nil, .loading?:
            return IntegrateStatus(icon: .loading, message: "Checking whether Git can rebase automatically…", buttonHelp: upToDateHelp)
        case .invalid?:
            return IntegrateStatus(icon: .invalid, message: "Can't start the rebase. Check that you chose a valid branch.", buttonHelp: upToDateHelp)
        case .conflicts?:
            // There are no words for it (the state layer's previews never
            // predict conflicts): no line rather than a lone symbol.
            return IntegrateStatus(canStart: true)
        case .clean(let commitsAhead, let commitsBehind)?:
            let ahead = commitsAhead.count
            let behind = commitsBehind.count
            if behind > 0, ahead <= 0 {
                let commits = behind == 1 ? "commit" : "commits"
                return IntegrateStatus(
                    icon: .clean,
                    message: "This will fast-forward \(current) by \(behind) \(commits) to match \(base)",
                    canStart: true
                )
            }
            if behind > 0, ahead > 0 {
                let commits = ahead == 1 ? "commit" : "commits"
                return IntegrateStatus(
                    icon: .clean,
                    message: "This will update \(current) by applying its \(ahead) \(commits) on top of \(base)",
                    canStart: true
                )
            }
            return IntegrateStatus(icon: .clean, message: "\(current) is already up to date with \(base)", buttonHelp: upToDateHelp)
        }
    }
}

/// The Integrate sheet: Merge into, Squash and Merge into, or Rebase the
/// current branch.
public struct IntegrateBranchSheet: View {
    static let sheetID = "espalier.integrate"

    private let repository: RepositoryModel
    private let onStart: (IntegrateMethod, Branch) -> Void
    @State private var method: IntegrateMethod
    @State private var selection: Branch?
    @State private var mergePreview: MergePreview?
    @State private var rebasePreview: RebasePreview?
    @Environment(\.dismissModal) private var dismissModal

    /// The list's height.
    private static let listHeight = Metrics.BranchPicker.sheetListHeight

    public init(repository: RepositoryModel, method: IntegrateMethod, initialBranch: Branch?, onStart: @escaping (IntegrateMethod, Branch) -> Void) {
        self.repository = repository
        self.onStart = onStart
        _method = State(initialValue: method)
        _selection = State(initialValue: initialBranch ?? Self.defaultSelection(in: repository))
    }

    /// The branch preselected: the default branch unless it's the current
    /// one.
    @MainActor
    static func defaultSelection(in repository: RepositoryModel) -> Branch? {
        let state = repository.gitState
        guard let defaultBranch = state.branches.defaultBranch, defaultBranch.ref != state.tip.branch?.ref else {
            return nil
        }
        return defaultBranch
    }

    public var body: some View {
        let current = repository.gitState.tip.branch?.name ?? ""
        let status = self.status(current: current)
        SheetScaffold(method.title(currentBranch: current)) {
            BranchPicker(
                repository: repository,
                selection: $selection,
                onActivate: { branch in
                    if branch.ref == selection?.ref, status.canStart {
                        start(branch)
                    }
                }
            )
            .frame(height: Self.listHeight)
            IntegrateStatusLine(status: status)
        } buttons: {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) {
                dismissModal()
            }
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            IntegrateMethodButton(method: $method, canStart: status.canStart, help: status.buttonHelp) {
                if let selection {
                    start(selection)
                }
            }
        }
        .task(id: PreviewKey(method: method, selection: selection, current: repository.gitState.tip.branch)) {
            await loadPreview()
        }
    }

    private func status(current: String) -> IntegrateStatus {
        switch method {
        case .merge, .squashMerge:
            IntegrateStatus.merge(current: current, branch: selection?.name, preview: mergePreview)
        case .rebase:
            IntegrateStatus.rebase(current: current, base: selection?.name, preview: rebasePreview)
        }
    }

    private func loadPreview() async {
        guard let selection, selection.ref != repository.gitState.tip.branch?.ref else {
            return
        }
        switch method {
        case .merge, .squashMerge:
            mergePreview = nil
            let preview = await repository.operations.mergePreview(of: selection)
            if !Task.isCancelled {
                mergePreview = preview
            }
        case .rebase:
            rebasePreview = nil
            let preview = await repository.operations.rebasePreview(onto: selection)
            if !Task.isCancelled {
                rebasePreview = preview
            }
        }
    }

    private func start(_ branch: Branch) {
        dismissModal()
        onStart(method, branch)
    }

    /// Shows the sheet in the window, preselecting `branch` (by name).
    static func present(_ method: IntegrateMethod, branch name: String?, in context: WindowContext) {
        guard let repository = context.repository else {
            return
        }
        let initial = name.flatMap { HistoryCommits.branch(named: $0, in: repository) }
        context.modals.presentSheet(id: sheetID) {
            IntegrateBranchSheet(repository: repository, method: method, initialBranch: initial) { [weak context] method, branch in
                guard let context else {
                    return
                }
                Task {
                    await BranchActions.integrate(method, branch: branch, in: context)
                }
            }
        }
    }
}

/// What a preview depends on.
private struct PreviewKey: Equatable {
    let method: IntegrateMethod
    let selectionRef: String?
    let selectionTip: String?
    let currentTip: String?

    init(method: IntegrateMethod, selection: Branch?, current: Branch?) {
        // A merge and a squash merge share their preview.
        self.method = method == .squashMerge ? .merge : method
        selectionRef = selection?.ref
        selectionTip = selection?.tip.sha
        currentTip = current?.tip.sha
    }
}

/// The status line: its symbol and message. The sheet and Compare's call
/// to action show it alike.
struct IntegrateStatusLine: View {
    let status: IntegrateStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            if let icon = status.icon {
                IntegrateStatusIcon(icon: icon)
            }
            Text(status.message ?? " ")
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status line's symbol: the arc while checking, then a check, a
/// warning, or a cross.
struct IntegrateStatusIcon: View {
    let icon: IntegrateStatus.Icon

    var body: some View {
        switch icon {
        case .loading:
            ArcProgress(.mini)
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
        }
    }
}

/// The method's split button, in the sheet and Compare's call to action:
/// its main part starts the method; its menu switches the method, each
/// with its description, the current one checked. While the method can't
/// start, the whole button opens the menu, so the method can still be
/// switched.
struct IntegrateMethodButton: View {
    @Binding var method: IntegrateMethod
    let canStart: Bool
    /// The tooltip; the method's description when nil.
    let help: String?
    /// The main part's shortcut: Return in the sheet, whose default button
    /// it is.
    var shortcut: KeyboardShortcut? = .defaultAction
    let start: () -> Void

    var body: some View {
        if canStart {
            SplitCapsuleButton(.prominent, menuLabel: "Merge Options", shortcut: shortcut, action: start) {
                Text(method.label)
            } menu: {
                options
            }
            .fixedSize()
            .tooltip(help ?? method.description)
        } else {
            PullDownButton("Merge Options", value: method.label) {
                options
            } label: {
                MenuCapsuleLabel(method.label)
            }
            .buttonStyle(.quiet)
            .fixedSize()
            .tooltip(help ?? method.description)
        }
    }

    /// The methods, each with its description, the current one checked.
    private var options: MenuContent {
        MenuContent {
            MenuPicker(selection: $method) {
                for option in IntegrateMethod.allCases {
                    MenuChoice(option.label, value: option, subtitle: option.description)
                }
            }
        }
    }
}
