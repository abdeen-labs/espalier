// Create Pull Request: the repository it opens in, the base branch to merge
// into (`BranchPicker`, limited to branches on the pull request's remote)
// and the branch it comes from, Title and Description as GitHub's form seeds
// them (`pullRequestSeed(head:base:)`: the only commit's message, else the
// branch's name, and the repository's template), "Create as draft", and
// Create Pull Request (`createPullRequest(_:)`), which closes the sheet and
// shows the new pull request's place. GitHub's refusals show in the sheet,
// so the pull request can be changed and created again.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the sheet shows besides its fields.
nonisolated struct CreatePullRequestContent: Sendable, Equatable {
    /// Where the pull request opens ("octocat/hello").
    var repositoryName: String?
    /// The base branch's name; nil when there's none.
    var base: String?
    /// The branch it comes from, as GitHub shows it ("hubot:feature" from a
    /// fork).
    var head: String
    /// Whether it's being created.
    var isCreating: Bool
    /// Why the last try failed.
    var problem: String?
    /// Whether Create Pull Request works: there's a title and a base, and
    /// it isn't being created.
    var canCreate: Bool
}

/// The sheet's fields and work.
@MainActor @Observable
final class CreatePullRequestSheetModel {
    @ObservationIgnored let repository: RepositoryModel
    /// The branch the pull request comes from.
    let head: Branch
    var title = ""
    var body = ""
    var isDraft = false
    /// The branch it merges into.
    private(set) var base: Branch?
    private(set) var isCreating = false
    /// Why the last try failed.
    var problem: String?
    /// The seed the fields took last: a field that still says it takes the
    /// next one (after choosing another base).
    @ObservationIgnored private var appliedSeed = PullRequestSeed(title: "", body: "")
    /// Bumped by each seed load, so only the latest applies.
    @ObservationIgnored private var seedGeneration = 0

    init(repository: RepositoryModel, head: Branch, base: Branch?) {
        self.repository = repository
        self.head = head
        self.base = base
    }

    var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && base != nil && !isCreating
    }

    var content: CreatePullRequestContent {
        CreatePullRequestContent(
            repositoryName: getNonForkGitHubRepository(repository.record)?.fullName,
            base: base?.name,
            head: repository.gitHub.pullRequestHeadName(head),
            isCreating: isCreating,
            problem: problem,
            canCreate: canCreate
        )
    }

    /// The branches it can merge into.
    var baseCandidates: [Branch] {
        repository.history.pullRequestPreview.baseBranchCandidates
    }

    /// Fills the title and body from the branch's commits and the
    /// repository's template; a field the user changed keeps what they
    /// wrote.
    func seed() async {
        seedGeneration &+= 1
        let generation = seedGeneration
        let seed = await repository.gitHub.pullRequestSeed(head: head, base: base)
        guard generation == seedGeneration else {
            return
        }
        if title == appliedSeed.title {
            title = seed.title
        }
        if body == appliedSeed.body {
            body = seed.body
        }
        appliedSeed = seed
    }

    /// Merges into `branch` instead, and seeds the fields for it.
    func chooseBase(_ branch: Branch) async {
        base = branch
        await seed()
    }

    /// Creates the pull request through the presenter, which answers its
    /// questions; its errors become `problem`.
    ///
    /// - Returns: The new pull request; nil when it wasn't created.
    func create(presenter: WindowPresenter) async -> PullRequest? {
        guard canCreate, let base else {
            return nil
        }
        problem = nil
        isCreating = true
        defer { isCreating = false }
        let request = NewPullRequest(title: title, body: body, head: head, base: base, isDraft: isDraft)
        let gitHub = repository.gitHub
        do throws(OperationError) {
            return try await presenter.performThrowing { _ throws(OperationError) in
                try await gitHub.createPullRequest(request)
            }
        } catch {
            problem = error.message
            return nil
        }
    }
}

/// Creates a pull request from the current branch.
struct CreatePullRequestSheet: View {
    static let sheetID = "espalier.github.createPullRequest"

    @State var model: CreatePullRequestSheetModel
    @State private var isPickingBase = false
    @State private var baseNote: String?
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismissModal

    var body: some View {
        @Bindable var fields = model
        CreatePullRequestForm(
            content: model.content,
            title: $fields.title,
            bodyText: $fields.body,
            isDraft: $fields.isDraft,
            isPickingBase: $isPickingBase,
            baseNote: baseNote,
            cancel: { dismissModal() },
            create: create
        ) {
            BranchPicker(
                repository: model.repository,
                selection: baseSelection,
                includesRemoteBranches: true,
                candidates: model.baseCandidates
            )
            .frame(width: 320, height: 360)
            .padding(Metrics.insetMedium)
            .background(Color(espalier: Palette.background))
        }
        .task {
            await model.seed()
        }
    }

    /// The base branch picker's selection: a branch on the pull request's
    /// remote becomes the base; any other says it can't be one.
    private var baseSelection: Binding<Branch?> {
        Binding(
            get: { model.base },
            set: { branch in
                guard let branch else {
                    return
                }
                switch PreviewPullRequestSheet.chooseBase(branch, candidates: model.baseCandidates) {
                case .refused(let note):
                    baseNote = note
                case .base(let base):
                    baseNote = nil
                    isPickingBase = false
                    let model = model
                    Task {
                        await model.chooseBase(base)
                    }
                }
            }
        )
    }

    private func create() {
        let model = model
        let context = context
        let dismissModal = dismissModal
        Task {
            guard let pullRequest = await model.create(presenter: context.presenter) else {
                return
            }
            dismissModal()
            Self.show(pullRequest, of: model.repository, in: context)
        }
    }

    /// Shows `pullRequest`'s place, while the window still shows its
    /// repository: from the list when it's there, else as GitHub described
    /// it.
    static func show(_ pullRequest: PullRequest, of repository: RepositoryModel, in context: WindowContext) {
        guard context.repository?.id == repository.id else {
            return
        }
        let number = pullRequest.pullRequestNumber
        if repository.gitHub.openPullRequests.contains(where: { $0.pullRequestNumber == number }) {
            context.select(.pullRequest(number: number))
        } else {
            context.state.show(linked: pullRequest, in: repository.id)
        }
    }

    /// Shows the sheet for a pull request from `head` into `base` (the
    /// default branch when nil).
    static func present(head: Branch, base: Branch?, repository: RepositoryModel, in context: WindowContext) {
        let model = CreatePullRequestSheetModel(
            repository: repository,
            head: head,
            base: base ?? repository.gitState.branches.defaultBranch
        )
        context.modals.presentSheet(id: sheetID) {
            CreatePullRequestSheet(model: model)
        }
    }
}

extension Metrics.Sheet {
    /// Create Pull Request's width, and its description's height.
    public static let createPullRequestWidth: CGFloat = 600
    public static let pullRequestDescriptionHeight: CGFloat = 200
}

/// The sheet's content: the branches, Title, Description, "Create as
/// draft", what went wrong, and the buttons.
struct CreatePullRequestForm<BasePicker: View>: View {
    let content: CreatePullRequestContent
    @Binding var title: String
    @Binding var bodyText: String
    @Binding var isDraft: Bool
    @Binding var isPickingBase: Bool
    /// Why the branch picked can't be the base.
    let baseNote: String?
    let cancel: () -> Void
    let create: () -> Void
    let basePicker: () -> BasePicker
    @FocusState private var isTitleFocused: Bool

    /// - Parameter basePicker: The base branch picker, in the base's popover.
    init(
        content: CreatePullRequestContent,
        title: Binding<String>,
        bodyText: Binding<String>,
        isDraft: Binding<Bool>,
        isPickingBase: Binding<Bool>,
        baseNote: String? = nil,
        cancel: @escaping () -> Void = {},
        create: @escaping () -> Void = {},
        @ViewBuilder basePicker: @escaping () -> BasePicker
    ) {
        self.content = content
        _title = title
        _bodyText = bodyText
        _isDraft = isDraft
        _isPickingBase = isPickingBase
        self.baseNote = baseNote
        self.cancel = cancel
        self.create = create
        self.basePicker = basePicker
    }

    var body: some View {
        SheetScaffold("Create Pull Request", message: content.repositoryName, width: Metrics.Sheet.createPullRequestWidth) {
            branches
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Title")
                TextField("Title", text: $title, prompt: Text("Add a title").fieldPrompt())
                    .textFieldStyle(.capsule)
                    .labelsHidden()
                    .focused($isTitleFocused)
            }
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Description")
                TextEditor(text: $bodyText)
                    .font(Typography.row)
                    .scrollContentBackground(.hidden)
                    .textAreaSurface()
                    .overlay(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("Add a description")
                                .font(Typography.row)
                                .foregroundStyle(Color(nsColor: Palette.placeholderText))
                                .padding(.horizontal, Metrics.TextArea.horizontalInset + Metrics.TextArea.lineFragmentPadding)
                                .padding(.vertical, Metrics.TextArea.verticalInset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: Metrics.Sheet.pullRequestDescriptionHeight)
                    .accessibilityLabel("Description")
            }
            Toggle("Create as draft", isOn: $isDraft)
                .toggleStyle(.checkboxMark)
            if let problem = content.problem {
                FieldMessage(problem, kind: .error)
            }
        } buttons: {
            SheetButtons(
                "Create Pull Request",
                isConfirmDisabled: !content.canCreate,
                isWorking: content.isCreating,
                cancel: cancel,
                confirm: create
            )
        }
        .disabled(content.isCreating)
        .onAppear {
            isTitleFocused = true
        }
    }

    /// "Merge into <base> from <branch>.", the base a capsule that opens the
    /// picker.
    private var branches: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
            HStack(spacing: Metrics.insetSmall) {
                Text("Merge into")
                    .foregroundStyle(.text2)
                Button {
                    isPickingBase = true
                } label: {
                    MenuCapsuleLabel("base: \(content.base ?? "Choose\u{2026}")")
                        .font(Typography.secondary.monospaced())
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .popoverCard(isPresented: $isPickingBase, title: "Base Branch", content: basePicker)
                Text("from")
                    .foregroundStyle(.text2)
                QuietCapsule(content.head, monospaced: true)
                Text(".")
                    .foregroundStyle(.text2)
            }
            if let baseNote {
                FieldMessage(baseNote, kind: .error)
            }
        }
    }
}
