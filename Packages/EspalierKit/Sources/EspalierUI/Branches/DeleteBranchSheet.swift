// Ported in part from desktop/app/src/ui/delete-branch/delete-pull-request-dialog.tsx
//
// Deleting a branch that may have an open pull request deletes only the
// local branch, and says so. Branches without a pull request ask through
// the state layer's `deleteBranch` confirmation, which the presenter shows
// as a compact sheet with "Delete it on the remote too" when the branch
// exists there. This sheet looks and answers like that one: Delete is the
// default button.

import EspalierCore
import GitKit
import SwiftUI

/// What the pull request variant of Delete Branch shows.
nonisolated public struct DeleteBranchSheetContent: Sendable, Equatable {
    public var branchName: String
    public var pullRequestNumber: Int

    public init(branchName: String, pullRequestNumber: Int) {
        self.branchName = branchName
        self.pullRequestNumber = pullRequestNumber
    }

    public var title: String {
        "Delete Branch?"
    }

    public var message: String {
        "Delete the branch \(branchName)? It may have an open pull request associated with it."
    }

    /// The second paragraph, around the pull request's number (a link).
    public var mergedHintBeforeNumber: String {
        "If "
    }

    public var mergedHintAfterNumber: String {
        " has been merged, you can also go to GitHub to delete the remote branch."
    }
}

/// Delete Branch for a branch that may have an open pull request: deletes
/// only the local branch.
public struct DeleteBranchSheet: View {
    static let sheetID = "espalier.deleteBranch"

    private let content: DeleteBranchSheetContent
    private let onDelete: () -> Void
    private let onViewPullRequest: () -> Void
    @Environment(\.dismissModal) private var dismissModal

    public init(_ content: DeleteBranchSheetContent, onDelete: @escaping () -> Void, onViewPullRequest: @escaping () -> Void) {
        self.content = content
        self.onDelete = onDelete
        self.onViewPullRequest = onViewPullRequest
    }

    public var body: some View {
        SheetScaffold(content.title, message: content.message, width: Metrics.Sheet.compactWidth) {
            // The number is a link inside the sentence, so the sentence
            // wraps as one.
            LinkedText(mergedHint)
                .font(Typography.row)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in
                    onViewPullRequest()
                    return .handled
                })
        } buttons: {
            SheetButtons("Delete", confirmRole: .destructive, cancel: { dismissModal() }) {
                dismissModal()
                onDelete()
            }
        }
    }

    /// "If #142 has been merged, …", the number a link that shows the pull
    /// request (the URL only marks it: the sheet's `openURL` handles it).
    private var mergedHint: AttributedString {
        var number = AttributedString("#\(content.pullRequestNumber)")
        number.link = URL(string: "espalier-pull-request:\(content.pullRequestNumber)")
        return AttributedString(content.mergedHintBeforeNumber) + number + AttributedString(content.mergedHintAfterNumber)
    }

    /// Shows the sheet for `branch`, whose pull request is `number`.
    static func present(_ branch: Branch, pullRequestNumber number: Int, in context: WindowContext) {
        guard context.repository != nil else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            DeleteBranchSheet(
                DeleteBranchSheetContent(branchName: branch.name, pullRequestNumber: number),
                onDelete: { [weak context] in
                    guard let context else {
                        return
                    }
                    Task {
                        await BranchActions.deleteLocalBranch(branch, in: context)
                    }
                },
                onViewPullRequest: { [weak context] in
                    context?.actions.perform(.viewPullRequestOnGitHub(number: number))
                }
            )
        }
    }
}
