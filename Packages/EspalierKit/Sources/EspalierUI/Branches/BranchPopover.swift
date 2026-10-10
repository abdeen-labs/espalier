// The location control's branch popover, opened with ⌘B. The list is the
// branch picker in the palette's look; Return or a double-click checks the
// branch out through the Switch Branch decision; a filter that matches
// nothing offers Create New Branch; the footer has New Branch… (⇧⌘N) and
// Check Out, with their keys.

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
                style: .palette
            )
            .frame(height: Metrics.BranchPicker.popoverListHeight)
            Hairline()
            HStack(spacing: Metrics.insetSmall) {
                Button {
                    context.state.isBranchPopoverPresented = false
                    context.actions.perform(.newBranch(startPoint: nil))
                } label: {
                    HStack(spacing: Metrics.insetSmall) {
                        Text(ActionKind.newBranch.title)
                        if let shortcut = ActionKind.newBranch.shortcut {
                            KeyCap(shortcut.symbols)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([ActionKind.newBranch.title, ActionKind.newBranch.shortcut?.symbols].compactMap(\.self).joined(separator: " "))
                }
                .buttonStyle(.quiet)
                .disabled(!context.actions.canPerform(.newBranch(startPoint: nil)))
                Spacer()
                Button {
                    if let selection {
                        checkOut(selection)
                    }
                } label: {
                    HStack(spacing: Metrics.insetSmall) {
                        Text("Check Out")
                        KeyCap("↩", color: .white)
                    }
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCheckOut)
            }
            .controlSize(.small)
            .padding(.horizontal, Metrics.insetMedium)
            .padding(.vertical, Metrics.insetSmall + 2)
        }
        .frame(width: Metrics.BranchPicker.popoverWidth)
        .background(Color(espalier: Palette.background))
        .flatPopoverPresentation()
    }

    private var canCheckOut: Bool {
        guard let selection else {
            return false
        }
        return selection.ref != repository.gitState.tip.branch?.ref
            && context.actions.canPerform(.checkoutBranch(name: selection.name))
    }

    private func checkOut(_ branch: Branch) {
        guard branch.ref != repository.gitState.tip.branch?.ref else {
            return
        }
        context.state.isBranchPopoverPresented = false
        context.actions.perform(.checkoutBranch(name: branch.name))
    }
}
