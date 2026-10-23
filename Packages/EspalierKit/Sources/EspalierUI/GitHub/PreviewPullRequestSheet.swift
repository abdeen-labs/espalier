// Preview Pull Request (⌥⌘P), a sheet filling the window that
// `pullRequestPreview` loads: "Merge 3 commits into <base> from <branch>."
// with the base branch to choose (`BranchPicker`, limited to branches on
// the pull request's remote),
// the lines added and removed, the files beside the selected file's diff
// from the merge base (with the pull request diff's own Hide Whitespace
// setting), whether it merges cleanly, and Create Pull Request (or View Pull
// Request when the branch has one), which opens the Create Pull Request
// sheet with the base chosen here. With no base branch, or nothing to merge,
// a message says so.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The header line's and footer's content.
nonisolated struct PreviewPullRequestContent: Sendable, Equatable {
    /// The base branch's name, or nil when there's none.
    var baseBranch: String?
    var headBranch: String
    var commitCount: Int
    var linesAdded: Int
    var linesDeleted: Int
    /// The merge status's bold part and the rest, and its kind.
    var mergeTitle: String?
    var mergeMessage: String?
    var mergeKind: MergeStatusKind?
    /// Whether the branch has a pull request already: View Pull Request.
    var hasPullRequest: Bool
    /// Whether the button works (there are commits to merge).
    var canCreate: Bool
    /// "View on GitHub Enterprise" wording for the button's help.
    var isEnterprise: Bool

    enum MergeStatusKind: Sendable, Equatable {
        case checking, clean, conflicts, invalid

        /// The kind of the preview's merge status; nil before it's checked.
        init?(_ status: MergeTreeResult?) {
            switch status {
            case nil: return nil
            case .loading?: self = .checking
            case .clean?: self = .clean
            case .conflicts?: self = .conflicts
            case .invalid?: self = .invalid
            }
        }
    }

    /// "3 commits", the count in `numberFormat`.
    func commits(_ numberFormat: NumberFormat) -> String {
        "\(formatCount(commitCount, numberFormat)) commit\(commitCount == 1 ? "" : "s")"
    }

    /// "10 added lines, 2 removed lines", the counts in `numberFormat`.
    func lines(_ numberFormat: NumberFormat) -> String {
        "\(formatCount(linesAdded, numberFormat)) added lines, \(formatCount(linesDeleted, numberFormat)) removed lines"
    }

    /// The button's title and help.
    var buttonTitle: String {
        hasPullRequest ? "View Pull Request" : "Create Pull Request"
    }

    var buttonHelp: String {
        "\(hasPullRequest ? "View" : "Create") pull request on GitHub\(isEnterprise ? " Enterprise" : "")."
    }
}

/// Previews the pull request the current branch would open.
struct PreviewPullRequestSheet: View {
    static let sheetID = "espalier.github.previewPullRequest"

    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismissModal
    @Environment(\.numberFormat) private var numberFormat
    @State private var isPickingBase = false
    @State private var pickedBase: Branch?
    @State private var baseNote: String?

    var body: some View {
        let preview = repository.history.pullRequestPreview
        VStack(spacing: 0) {
            header(preview)
                .padding(Metrics.Sheet.padding)
            Hairline()
            changes(preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            PreviewPullRequestFooter(
                content: content(preview),
                cancel: { dismissModal() },
                create: create
            )
            .padding(.horizontal, Metrics.Sheet.padding)
            .padding(.vertical, Metrics.insetMedium)
        }
        .frame(
            minWidth: Metrics.Sheet.previewPullRequestMinimumSize.width,
            idealWidth: Metrics.Sheet.previewPullRequestSize.width,
            maxWidth: .infinity,
            minHeight: Metrics.Sheet.previewPullRequestMinimumSize.height,
            idealHeight: Metrics.Sheet.previewPullRequestSize.height,
            maxHeight: .infinity
        )
        .background(Color(espalier: Palette.background))
        .modalTitle("Preview Pull Request")
        .modalCardFillsWindow()
        .task {
            await repository.history.previewPullRequest()
        }
        .onDisappear {
            preview.close()
        }
    }

    private func content(_ preview: PullRequestPreviewModel) -> PreviewPullRequestContent {
        let changeset = preview.selection.changeset.value
        return PreviewPullRequestContent(
            baseBranch: preview.baseBranch?.name,
            headBranch: preview.headBranch?.name ?? repository.gitState.tip.branch?.name ?? "",
            commitCount: preview.commits.count,
            linesAdded: changeset?.linesAdded ?? 0,
            linesDeleted: changeset?.linesDeleted ?? 0,
            mergeTitle: preview.mergeStatusMessage?.title,
            mergeMessage: preview.mergeStatusMessage?.message,
            mergeKind: PreviewPullRequestContent.MergeStatusKind(preview.mergeStatus),
            hasPullRequest: repository.gitHub.currentPullRequest != nil,
            canCreate: !preview.commits.isEmpty || repository.gitHub.currentPullRequest != nil,
            isEnterprise: repository.record.gitHubRepository.map { !isDotCom($0.endpoint) } ?? false
        )
    }

    private func header(_ preview: PullRequestPreviewModel) -> some View {
        let content = content(preview)
        return VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Text("Preview Pull Request")
                .font(Typography.sheetTitle)
                .foregroundStyle(.text)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Metrics.insetSmall) {
                Text("Merge \(content.commits(numberFormat)) into")
                    .foregroundStyle(.text2)
                Button {
                    isPickingBase = true
                } label: {
                    MenuCapsuleLabel("base: \(content.baseBranch ?? "Choose…")")
                        .font(Typography.secondary.monospaced())
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .popoverCard(isPresented: $isPickingBase, title: "Base Branch") {
                    BranchPicker(
                        repository: repository,
                        selection: baseSelection(preview),
                        includesRemoteBranches: true,
                        candidates: preview.baseBranchCandidates
                    )
                        .frame(width: 320, height: 360)
                        .padding(Metrics.insetMedium)
                        .background(Color(espalier: Palette.background))
                }
                Text("from")
                    .foregroundStyle(.text2)
                // The period follows the branch as it would a word.
                HStack(spacing: 0) {
                    QuietCapsule(content.headBranch, monospaced: true)
                    Text(".")
                        .foregroundStyle(.text2)
                }
            }
            if let baseNote {
                SignInInlineError(message: baseNote)
            }
            if preview.status == .loaded, !preview.commits.isEmpty {
                Text(content.lines(numberFormat))
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The base branch picker's selection: a branch on the pull request's
    /// remote becomes the base; any other says it can't be one.
    private func baseSelection(_ preview: PullRequestPreviewModel) -> Binding<Branch?> {
        Binding(
            get: { pickedBase ?? preview.baseBranch },
            set: { branch in
                guard let branch else {
                    return
                }
                pickedBase = branch
                switch Self.chooseBase(branch, candidates: preview.baseBranchCandidates) {
                case .refused(let note):
                    baseNote = note
                case .base(let base):
                    baseNote = nil
                    isPickingBase = false
                    Task {
                        await preview.setBaseBranch(base)
                        pickedBase = nil
                    }
                }
            }
        )
    }

    /// What choosing a base branch does.
    enum BaseChoice: Equatable {
        /// It becomes the base.
        case base(Branch)
        /// It can't be the base: why.
        case refused(String)
    }

    /// A branch on the pull request's remote (one of `candidates`) becomes
    /// the base; any other is refused (the picker lists only the candidates,
    /// so this guards a stale list).
    static func chooseBase(_ branch: Branch, candidates: [Branch]) -> BaseChoice {
        guard candidates.contains(where: { $0.ref == branch.ref }) else {
            return .refused("You can only open pull requests against remote branches.")
        }
        return .base(branch)
    }

    @ViewBuilder
    private func changes(_ preview: PullRequestPreviewModel) -> some View {
        switch preview.status {
        case .idle, .loading:
            DelayedProgressView()
        case .noBaseBranch:
            CenteredMessage(
                "Could not find a default branch to compare against.",
                systemImage: "arrow.trianglehead.pull",
                description: "Select a base branch above."
            )
        case .changesNotAvailable:
            CenteredMessage("Changes Not Available", systemImage: "doc.text.magnifyingglass")
        case .failed(let error):
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
        case .loaded:
            if let empty = preview.emptyMessage {
                CenteredMessage(empty.title, systemImage: "arrow.trianglehead.pull", description: empty.message)
            } else {
                SplitView(autosaveName: "Espalier.Split.pullRequestPreviewFiles", leadingColumn: Metrics.Column.commitFileList) {
                    ChangedFilesList(
                        selection: preview.selection,
                        repositoryPath: repository.record.path,
                        menuContent: { file in PullRequestFileMenus.preview(file, repository: repository) }
                    ) { file in
                        preview.selectFile(file)
                    }
                } trailing: {
                    DiffContainer(preview.selection.diff, file: preview.selection.file.map(DiffFileInfo.init), context: .pullRequest)
                }
            }
        }
    }

    private func create() {
        let base = repository.history.pullRequestPreview.baseBranch
        dismissModal()
        if repository.gitHub.currentPullRequest != nil {
            context.actions.perform(.viewPullRequestOnGitHub(number: nil))
            return
        }
        Task {
            await CreatePullRequestPrompts.run(base: base, in: context)
        }
    }

    /// Shows the sheet for the current branch.
    @MainActor
    static func present(in context: WindowContext) {
        guard let repository = context.repository else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            PreviewPullRequestSheet(repository: repository)
        }
    }
}

extension Metrics.Sheet {
    /// Preview Pull Request: its size before it fills the window, and the
    /// smallest it gets.
    public static let previewPullRequestSize = CGSize(width: 960, height: 640)
    public static let previewPullRequestMinimumSize = CGSize(width: 760, height: 480)
}

/// The footer: whether it merges cleanly, then the buttons. The merge
/// check's progress and line crossfade into its result over 0.15 s.
struct PreviewPullRequestFooter: View {
    let content: PreviewPullRequestContent
    let cancel: () -> Void
    let create: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            if let title = content.mergeTitle {
                ZStack {
                    mergeGlyph
                        .id(content.mergeKind)
                        .transition(motion.animates ? .opacity : .identity)
                }
                .motion(Motion.leave, value: content.mergeKind)
                Text("\(Text(title).fontWeight(.semibold).foregroundStyle(.text)) \(content.mergeMessage ?? "")")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .lineLimit(2)
                    .contentTransition(motion.animates ? .opacity : .identity)
                    .motion(Motion.leave, value: content.mergeKind)
            }
            Spacer(minLength: Metrics.insetMedium)
            SheetButtons(content.buttonTitle, isConfirmDisabled: !content.canCreate, confirmHelp: content.buttonHelp, cancel: cancel, confirm: create)
        }
    }

    @ViewBuilder
    private var mergeGlyph: some View {
        switch content.mergeKind {
        case .checking?:
            ArcProgress(.small)
        case .clean?:
            ChecksGlyph(.success)
                .accessibilityLabel("Able to merge")
        case .conflicts?:
            WarningGlyph()
        case .invalid?:
            ChecksGlyph(.failure)
                .accessibilityLabel("Unable to merge")
        case nil:
            EmptyView()
        }
    }
}
