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

/// How a branch comes into the current one.
nonisolated public enum IntegrateMethod: String, Sendable, CaseIterable, Identifiable {
    case merge
    case squashMerge
    case rebase

    public var id: String {
        rawValue
    }

    /// The split button's label.
    public var label: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squashMerge: "Squash and merge"
        case .rebase: "Rebase"
        }
    }

    /// The option's description in the split button's menu.
    public var description: String {
        switch self {
        case .merge: "Adds the selected branch's commits to the current branch with a merge commit."
        case .squashMerge: "Combines the selected branch's commits into one commit on the current branch."
        case .rebase: "Replays the current branch's commits on top of the selected branch."
        }
    }

    /// "Merge into main", "Squash and Merge into main", "Rebase main".
    public func title(currentBranch: String) -> String {
        let name = truncate(currentBranch)
        switch self {
        case .merge: return "Merge into \(name)"
        case .squashMerge: return "Squash and Merge into \(name)"
        case .rebase: return "Rebase \(name)"
        }
    }

    /// `name`, cut to 40 characters with an ellipsis.
    private func truncate(_ name: String) -> String {
        name.count <= 40 ? name : "\(name.prefix(39))…"
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

/// The status line: its symbol and message.
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

/// The status line's symbol: a dot while checking, then a check, a
/// warning, or a cross.
struct IntegrateStatusIcon: View {
    let icon: IntegrateStatus.Icon

    var body: some View {
        switch icon {
        case .loading:
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(.text3)
                .accessibilityLabel("Checking")
        case .clean:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityLabel("Clean")
        case .conflicts:
            WarningGlyph()
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityLabel("Unable")
        }
    }
}

/// The split button: its main part starts the method; its menu switches
/// the method, each with its description. While the method can't start,
/// the whole button opens the menu, so the method can still be switched.
struct IntegrateMethodButton: View {
    @Binding var method: IntegrateMethod
    let canStart: Bool
    let help: String?
    let start: () -> Void

    var body: some View {
        if canStart {
            // Return starts the method, as the sheet's default button.
            SplitCapsuleButton(.prominent, menuLabel: "Merge Options", shortcut: .defaultAction, action: start) {
                Text(method.label)
            } menu: {
                options
            }
            .fixedSize()
            .help(help ?? method.description)
        } else {
            Menu {
                options
            } label: {
                MenuCapsuleLabel(method.label)
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help ?? method.description)
        }
    }

    @ViewBuilder
    private var options: some View {
        ForEach(IntegrateMethod.allCases) { option in
            Button {
                method = option
            } label: {
                if option == method {
                    Label {
                        Text(option.label)
                        Text(option.description)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                } else {
                    Text(option.label)
                    Text(option.description)
                }
            }
        }
    }
}
