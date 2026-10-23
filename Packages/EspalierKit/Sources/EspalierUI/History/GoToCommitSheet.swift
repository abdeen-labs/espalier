// Go ▸ Go to Commit…: a SHA (4 to 64 hexadecimal digits) is found in the
// history, loading pages until it's there, and selected; one that isn't in
// the history's scope says so. And Branch ▸ Compare to Branch…, which picks
// the branch Compare shows. Both sit in the shared `SheetScaffold`.

import EspalierCore
import GitKit
import SwiftUI

/// What going to a commit says while it runs or after it failed.
nonisolated enum GoToCommitStatus: Sendable, Equatable {
    case searching
    case notFound(String)
    case notInHistory

    var message: String? {
        switch self {
        case .searching: nil
        case .notFound(let sha): "No commit matches “\(sha)”."
        case .notInHistory: "That commit isn't on the branches the history shows. Choose All Branches to see more."
        }
    }
}

/// The Go to Commit sheet's content. Why a commit wasn't found fades in
/// under the field over 0.22 s and out over 0.15 s, as does loading older
/// commits beside the buttons.
struct GoToCommitForm: View {
    @Binding var text: String
    let status: GoToCommitStatus?
    var cancel: () -> Void = {}
    var go: () -> Void = {}
    @FocusState private var isFocused: Bool

    /// Whether `text` can name a commit: 4 to 64 hexadecimal digits.
    static func isCommitID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (4...64).contains(trimmed.count) && trimmed.allSatisfy(\.isHexDigit)
    }

    var body: some View {
        SheetScaffold("Go to Commit", width: Metrics.Sheet.compactWidth) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                TextField("SHA", text: $text, prompt: Text("Commit SHA").fieldPrompt())
                    .textFieldStyle(.capsule(font: AppKitTypography.shaField))
                    .focused($isFocused)
                    .onSubmit {
                        if Self.isCommitID(text) {
                            go()
                        }
                    }
                if let message = status?.message {
                    FieldMessage(message, kind: status == .notInHistory ? .note : .error)
                        .barTransition()
                }
            }
        } buttons: {
            if status == .searching {
                Group {
                    ArcProgress(.small)
                    Text("Loading older commits\u{2026}")
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                }
                .barTransition()
            }
            SheetButtons(
                "Go",
                isConfirmDisabled: !Self.isCommitID(text) || status == .searching,
                cancel: cancel,
                confirm: go
            )
        }
        .onAppear {
            isFocused = true
        }
    }
}

/// Go to Commit.
struct GoToCommitSheet: View {
    static let sheetID = "history.goToCommit"

    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var text = ""
    @State private var status: GoToCommitStatus?

    var body: some View {
        GoToCommitForm(text: $text, status: status, cancel: cancel, go: go)
    }

    private func go() {
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = repository.history
        let navigator = context.state.history.navigator
        status = .searching
        Task {
            let result = await navigator.goToCommit(sha, in: history)
            switch result {
            case .found, .foundInMerge:
                dismiss()
            case .notFound:
                status = .notFound(sha)
            case .notInHistory:
                status = .notInHistory
            case .cancelled:
                status = nil
            }
        }
    }

    private func cancel() {
        if status == .searching {
            context.state.history.navigator.cancel()
            repository.history.cancelLoading()
        }
        dismiss()
    }

    static func present(repository: RepositoryModel, context: WindowContext) {
        context.modals.presentSheet(id: sheetID) {
            GoToCommitSheet(repository: repository)
        }
    }
}

/// Branch ▸ Compare to Branch…: picks the branch whose place shows its
/// comparison (Ahead), from every branch but the current one and fork
/// remotes', each with how far the current branch is behind and ahead of
/// it.
struct CompareToBranchSheet: View {
    static let sheetID = "history.compareToBranch"

    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var branch: Branch?

    var body: some View {
        SheetScaffold("Compare to Branch") {
            BranchPicker(
                repository: repository,
                selection: $branch,
                candidates: repository.history.comparableBranches,
                comparesWithCurrentBranch: true
            )
            .frame(height: 260)
        } buttons: {
            SheetButtons(
                "Compare",
                isConfirmDisabled: branch == nil || branch?.name == repository.gitState.tip.branch?.name,
                cancel: { dismiss() },
                confirm: {
                    if let branch {
                        HistoryPlaces.showComparison(of: branch, in: context)
                    }
                    dismiss()
                }
            )
        }
    }

    static func present(repository: RepositoryModel, context: WindowContext) {
        context.modals.presentSheet(id: sheetID) {
            CompareToBranchSheet(repository: repository)
        }
    }
}
