// Ported in part from desktop/app/src/ui/branches/branches-container.tsx
//
// The location control's branch popover (⌘B), the branch switcher, laid
// out as desktop's: the filter with New Branch… (⇧⌘N) beside it, then the
// branches, whose click or Return checks the highlighted branch out
// through the Switch Branch decision (the current branch, highlighted as
// the popover opens, only closes it), and whose right-click opens the
// sidebar's branch menu; a filter that matches nothing offers Create New
// Branch. Along the bottom, "Choose a branch to merge into <current>"
// (Merge into Current Branch…) turns the list into a picker for the merge:
// the current branch and fork remotes' branches leave it, New Branch… goes,
// and the bottom says what the pick is for, with Cancel, which turns it
// back. The Branch menu's Merge into Current Branch…, Squash and Merge into
// Current Branch…, and Rebase Current Branch… open the popover as that
// picker. Picking a branch closes the popover and shows the branch's place
// with Ahead selected and the method chosen, where it starts
// (BranchActions).

import EspalierCore
import GitKit
import SwiftUI

/// The branch popover.
public struct BranchPopover: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.closeEnclosingPopover) private var closePopover
    @State private var selection: Branch?

    public init(repository: RepositoryModel) {
        self.repository = repository
        // The current branch is highlighted from the first frame.
        _selection = State(initialValue: repository.gitState.tip.branch)
    }

    public var body: some View {
        // What the list picks a branch for; nil while it switches branches.
        let method = context.state.branchPopoverMethod
        VStack(spacing: 0) {
            BranchPicker(
                repository: repository,
                selection: $selection,
                onActivate: { branch in
                    if let method {
                        pick(branch, for: method)
                    } else {
                        checkOut(branch)
                    }
                },
                // Offered when New Branch… is (not while an operation is in
                // progress), and not while picking.
                onCreateBranch: method == nil && context.actions.canPerform(.newBranch(startPoint: nil)) ? { name in
                    close()
                    NewBranchSheet.present(.create(initialName: name), in: context)
                } : nil,
                candidates: method == nil ? nil : repository.history.comparableBranches,
                style: .popover,
                filterAccessory: method == nil ? AnyView(newBranchButton) : nil,
                branchMenu: { [context] branch in
                    BranchContextMenu.content(ref: branch.ref, context: context)
                }
            )
            .frame(height: Metrics.BranchPicker.popoverListHeight)
            if let current = repository.gitState.tip.branch {
                Hairline()
                Group {
                    if let method {
                        BranchPickPrompt(method: method, currentBranch: current.name) {
                            context.state.branchPopoverMethod = nil
                        }
                    } else {
                        mergeButton(currentBranch: current.name)
                    }
                }
                .padding(.horizontal, Metrics.insetMedium)
                .padding(.vertical, Metrics.insetSmall)
            }
        }
        .frame(width: Metrics.BranchPicker.popoverWidth)
        .background(Color(espalier: Palette.background))
        .onChange(of: method, initial: true) { _, method in
            // A pick starts on the default branch, unless it's the current
            // one; switching branches, on the current branch.
            selection = method == nil ? repository.gitState.tip.branch : repository.history.defaultComparableBranch
        }
    }

    /// New Branch…, beside the filter; its shortcut is in its tooltip.
    private var newBranchButton: some View {
        Button {
            close()
            context.actions.perform(.newBranch(startPoint: nil))
        } label: {
            Label(ActionKind.newBranch.title, systemImage: "plus")
        }
        .buttonStyle(.quiet)
        .fixedSize()
        .tooltip([ActionKind.newBranch.title, ActionKind.newBranch.shortcut?.symbols].compactMap(\.self).joined(separator: " "))
        .disabled(!context.actions.canPerform(.newBranch(startPoint: nil)))
    }

    /// "Choose a branch to merge into <current>": Merge into Current
    /// Branch…, which turns the list into the merge's picker.
    private func mergeButton(currentBranch: String) -> some View {
        MergeIntoCurrentBranchButton(currentBranch: currentBranch) {
            context.actions.perform(.mergeIntoCurrentBranch(branch: nil))
        }
        .controlSize(.small)
        .disabled(!context.actions.canPerform(.mergeIntoCurrentBranch(branch: nil)))
    }

    /// Closes the popover, at once when it's in its card (so a sheet that
    /// opens next finds the window focused).
    private func close() {
        closePopover?()
        context.state.isBranchPopoverPresented = false
    }

    /// Checks `branch` out and closes the popover; the current branch only
    /// closes it.
    private func checkOut(_ branch: Branch) {
        close()
        guard branch.ref != repository.gitState.tip.branch?.ref else {
            return
        }
        context.actions.perform(.checkoutBranch(name: branch.name))
    }

    /// Picks `branch` for `method` and closes the popover.
    private func pick(_ branch: Branch, for method: CompareMethod) {
        close()
        Self.pick(branch, for: method, in: context)
    }

    /// Picks `branch` for the popover's merge, squash and merge, or rebase:
    /// closes the popover and shows the branch's place with Ahead selected
    /// and `method` chosen (Merge into Current Branch… with the branch).
    static func pick(_ branch: Branch, for method: CompareMethod, in context: WindowContext) {
        context.state.isBranchPopoverPresented = false
        context.actions.perform(BranchActions.integrationAction(method, branch: branch.ref))
    }
}

/// What the branch popover's pick is for, along its bottom while it picks:
/// the merge symbol, "Choose a branch to merge into <current>" (to squash
/// and merge into, to rebase <current> onto), the branch's name in
/// semibold and the middle of a long one left out, and Cancel, which turns
/// the list back to switching branches.
struct BranchPickPrompt: View {
    let method: CompareMethod
    let currentBranch: String
    let cancel: () -> Void

    /// The prompt's words before and after the current branch's name.
    private var words: (before: String, after: String) {
        switch method {
        case .merge: ("Choose a branch to merge into ", "")
        case .squashMerge: ("Choose a branch to squash and merge into ", "")
        case .rebase: ("Choose a branch to rebase ", " onto")
        }
    }

    var body: some View {
        let words = self.words
        let prompt = words.before + currentBranch + words.after
        HStack(spacing: Metrics.insetSmall) {
            Label {
                Text("\(words.before)\(Text(currentBranch).fontWeight(.semibold))\(words.after)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.accent)
            }
            .font(Typography.secondary)
            .foregroundStyle(.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tooltip(prompt)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(prompt)
            Button("Cancel", action: cancel)
                .buttonStyle(.quiet)
                .fixedSize()
        }
        .controlSize(.small)
    }
}

/// "Choose a branch to merge into <current>": a quiet button across the
/// popover with the merge symbol, the branch's name in semibold, the middle
/// of a long one left out.
struct MergeIntoCurrentBranchButton: View {
    let currentBranch: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Choose a branch to merge into \(Text(currentBranch).fontWeight(.semibold))")
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "arrow.triangle.merge")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.quiet)
        .tooltip("Choose a branch to merge into \(currentBranch)")
        .accessibilityLabel("Choose a branch to merge into \(currentBranch)")
    }
}
