// Ported in part from desktop/app/src/ui/branches/branches-container.tsx
//
// The location control's branch popover (⌘B), the branch switcher, laid
// out as desktop's: the filter with New Branch… (⇧⌘N) beside it, then the
// branches, whose click or Return checks the highlighted branch out
// through the Switch Branch decision (the current branch, highlighted as
// the popover opens, only closes it); a filter that matches nothing offers
// Create New Branch. Along the bottom, "Choose a branch to merge into
// <current>" opens Merge into Current Branch.

import EspalierCore
import GitKit
import SwiftUI

/// The branch popover.
public struct BranchPopover: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @State private var selection: Branch?

    public init(repository: RepositoryModel) {
        self.repository = repository
        // The current branch is highlighted from the first frame.
        _selection = State(initialValue: repository.gitState.tip.branch)
    }

    public var body: some View {
        VStack(spacing: 0) {
            BranchPicker(
                repository: repository,
                selection: $selection,
                onActivate: { branch in
                    checkOut(branch)
                },
                // Offered when New Branch… is (not while an operation is in
                // progress).
                onCreateBranch: context.actions.canPerform(.newBranch(startPoint: nil)) ? { name in
                    context.state.isBranchPopoverPresented = false
                    NewBranchSheet.present(.create(initialName: name), in: context)
                } : nil,
                style: .popover,
                filterAccessory: AnyView(newBranchButton)
            )
            .frame(height: Metrics.BranchPicker.popoverListHeight)
            if repository.gitState.tip.branch != nil {
                Hairline()
                mergeButton
                    .padding(.horizontal, Metrics.insetMedium)
                    .padding(.vertical, Metrics.insetSmall)
            }
        }
        .frame(width: Metrics.BranchPicker.popoverWidth)
        .background(Color(espalier: Palette.background))
        .flatPopoverPresentation()
    }

    /// New Branch…, beside the filter; its shortcut is in its tooltip.
    private var newBranchButton: some View {
        Button {
            context.state.isBranchPopoverPresented = false
            context.actions.perform(.newBranch(startPoint: nil))
        } label: {
            Label(ActionKind.newBranch.title, systemImage: "plus")
        }
        .buttonStyle(.quiet)
        .fixedSize()
        .help([ActionKind.newBranch.title, ActionKind.newBranch.shortcut?.symbols].compactMap(\.self).joined(separator: " "))
        .disabled(!context.actions.canPerform(.newBranch(startPoint: nil)))
    }

    /// "Choose a branch to merge into <current>", while HEAD is on a branch.
    @ViewBuilder
    private var mergeButton: some View {
        if let current = repository.gitState.tip.branch {
            MergeIntoCurrentBranchButton(currentBranch: current.name) {
                context.state.isBranchPopoverPresented = false
                context.actions.perform(.mergeIntoCurrentBranch(branch: nil))
            }
            .controlSize(.small)
            .disabled(!context.actions.canPerform(.mergeIntoCurrentBranch(branch: nil)))
        }
    }

    /// Checks `branch` out and closes the popover; the current branch only
    /// closes it.
    private func checkOut(_ branch: Branch) {
        context.state.isBranchPopoverPresented = false
        guard branch.ref != repository.gitState.tip.branch?.ref else {
            return
        }
        context.actions.perform(.checkoutBranch(name: branch.name))
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
        .help("Choose a branch to merge into \(currentBranch)")
        .accessibilityLabel("Choose a branch to merge into \(currentBranch)")
    }
}
