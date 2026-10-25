// The pull request place. Left: the overview (title, Draft, "#142 opened 2
// days ago by octo", the branches, Check Out through the uncommitted changes
// decision or "Checked Out" for the current branch's, View on GitHub, Check
// Out in New Worktree…, the checks with their steps, and the description in
// Markdown). Right: the changes since the merge base when the pull request's
// head is in the repository (`pullRequestChanges`), else "Changes Not
// Available" with a quiet Check Out (the overview's is the prominent one).
// A link's pull request is the one GitHub returned for it; another that
// isn't open (a notification's) loads from GitHub.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// A pull request: its overview and its changes.
public struct PullRequestScreen: View {
    private let repository: RepositoryModel
    private let number: Int
    @State private var fetched: FetchedPullRequest?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(repository: RepositoryModel, number: Int) {
        self.repository = repository
        self.number = number
    }

    /// The pull request a link showed here, if it's this one.
    private var linked: PullRequest? {
        guard let linked = context?.state.linkedPullRequest, linked.repositoryID == repository.id,
              linked.pullRequest.pullRequestNumber == number else {
            return nil
        }
        return linked.pullRequest
    }

    public var body: some View {
        let pullRequest = linked
            ?? repository.gitHub.openPullRequests.first { $0.pullRequestNumber == number }
            ?? fetched.flatMap { $0.number == number ? $0.pullRequest : nil }
        SplitView(.pullRequest) {
            if let pullRequest {
                PullRequestOverview(repository: repository, pullRequest: pullRequest)
            } else if fetched?.number == number {
                PullRequestNotFound(repository: repository, number: number)
            } else {
                DelayedProgressView()
            }
        } trailing: {
            if let pullRequest {
                PullRequestChangesView(repository: repository, pullRequest: pullRequest)
            } else {
                Color(nsColor: Palette.background)
            }
        }
        .task(id: number) {
            guard linked == nil, !repository.gitHub.openPullRequests.contains(where: { $0.pullRequestNumber == number }) else {
                return
            }
            let loaded = await repository.gitHub.pullRequest(number: number)
            guard !Task.isCancelled else {
                return
            }
            fetched = FetchedPullRequest(number: number, pullRequest: loaded)
        }
    }

    /// A pull request loaded from GitHub (nil: it couldn't be).
    private struct FetchedPullRequest {
        let number: Int
        let pullRequest: PullRequest?
    }
}

/// A pull request that couldn't be loaded.
private struct PullRequestNotFound: View {
    let repository: RepositoryModel
    let number: Int
    @Environment(WindowContext.self) private var context

    var body: some View {
        CenteredMessage(
            "Pull Request #\(number)",
            systemImage: "arrow.trianglehead.pull",
            description: "Couldn't load this pull request. It may have been closed, or its branch deleted.",
            isLarge: true
        ) {
            if let url = pageURL {
                Button("View on GitHub") {
                    context.app.integrations.openInBrowser(url)
                }
                .buttonStyle(.quiet)
            }
        }
        .fillingSpace()
    }

    private var pageURL: URL? {
        getNonForkGitHubRepository(repository.record).flatMap { GitHubWebURLs.pullRequest(number: number, in: $0) }
    }
}

// MARK: The overview

/// What the overview's header shows.
nonisolated struct PullRequestOverviewContent: Sendable, Equatable {
    var number: Int
    var title: String
    var isDraft: Bool
    var author: String
    var authorEndpoint: String?
    /// The author's avatar URL from the API, when it's known.
    var authorAvatarURL: String?
    var created: Date
    /// The branch it merges into ("main").
    var base: String
    /// The branch it comes from: "octo:feature/sign-in" from a fork,
    /// "feature/sign-in" from the same repository.
    var head: String
    /// Whether it's the current branch's pull request: "Checked Out" shows
    /// in Check Out's place.
    var isCurrentBranch: Bool
    /// The pull request's page.
    var url: URL?
    /// "View on GitHub", or "View on GitHub Enterprise".
    var viewOnGitHubTitle: String

    init(
        number: Int,
        title: String,
        isDraft: Bool,
        author: String,
        authorEndpoint: String?,
        authorAvatarURL: String? = nil,
        created: Date,
        base: String,
        head: String,
        isCurrentBranch: Bool,
        url: URL?,
        viewOnGitHubTitle: String = "View on GitHub"
    ) {
        self.number = number
        self.title = title
        self.isDraft = isDraft
        self.author = author
        self.authorEndpoint = authorEndpoint
        self.authorAvatarURL = authorAvatarURL
        self.created = created
        self.base = base
        self.head = head
        self.isCurrentBranch = isCurrentBranch
        self.url = url
        self.viewOnGitHubTitle = viewOnGitHubTitle
    }

    /// The author's avatar: the API's avatar URL, then the login's noreply
    /// address (an Enterprise Server's avatar URLs are behind private mode).
    /// Without the URL, a bot's avatar is known or looked up, a ghe.com
    /// user's is looked up, and others go by email.
    var authorAvatar: AvatarUser {
        AvatarUser(
            email: authorEndpoint.map { getLegacyStealthEmailForUser(author, $0) } ?? "",
            avatarURL: authorAvatarURL,
            name: author,
            endpoint: authorEndpoint
        )
    }

    init(_ pullRequest: PullRequest, isCurrentBranch: Bool) {
        let baseRepository = pullRequest.base.gitHubRepository
        let headRepository = pullRequest.head.gitHubRepository
        let isFromFork = headRepository.fullName != baseRepository.fullName
        self.init(
            number: pullRequest.pullRequestNumber,
            title: pullRequest.title,
            isDraft: pullRequest.draft,
            author: pullRequest.author,
            authorEndpoint: baseRepository.endpoint,
            authorAvatarURL: pullRequest.authorAvatarURL,
            created: pullRequest.created,
            base: pullRequest.base.ref,
            head: isFromFork ? "\(headRepository.owner.login):\(pullRequest.head.ref)" : pullRequest.head.ref,
            isCurrentBranch: isCurrentBranch,
            url: GitHubWebURLs.pullRequest(pullRequest),
            viewOnGitHubTitle: isDotCom(baseRepository.endpoint) ? "View on GitHub" : "View on GitHub Enterprise"
        )
    }
}

/// What the overview's buttons do.
struct PullRequestOverviewActions {
    var checkOut: () -> Void
    var checkOutInNewWorktree: (() -> Void)?
    var open: (URL) -> Void
    var checks: ChecksListActions
    /// Why Check Out can't run now (an operation in progress): it's
    /// disabled, with this as its tooltip.
    var checkOutRefusal: String? = nil
}

/// The overview, from the models.
struct PullRequestOverview: View {
    let repository: RepositoryModel
    let pullRequest: PullRequest
    @Environment(WindowContext.self) private var context
    @State private var description: ParsedDescription?

    var body: some View {
        let gitHub = repository.gitHub
        let branchName = pullRequest.head.ref
        let underlineLinks = context.app.preferences.underlineLinks
        PullRequestOverviewView(
            content: PullRequestOverviewContent(
                pullRequest,
                isCurrentBranch: gitHub.currentPullRequest?.pullRequestNumber == pullRequest.pullRequestNumber
            ),
            checks: ChecksContent(
                check: gitHub.checks(for: pullRequest),
                loaded: gitHub.hasLoadedChecks(for: pullRequest, branchName: branchName),
                repository: pullRequest.base.gitHubRepository,
                pullRequestNumber: pullRequest.pullRequestNumber,
                rerunSupport: gitHub.rerunSupport
            ),
            description: parsedDescription(underlineLinks: underlineLinks),
            actions: actions
        )
        .environment(\.openURL, OpenURLAction { url in
            context.app.integrations.openInBrowser(url)
            return .handled
        })
        // Choosing another pull request shows its overview at once: the
        // place is kept, so its checks' glyphs would otherwise animate.
        .motionScope(AnyHashable(MotionKey(repository: ObjectIdentifier(repository), number: pullRequest.pullRequestNumber)))
        .task(id: PullRequestKey(number: pullRequest.pullRequestNumber, branchName: branchName)) {
            await gitHub.watchChecks(for: pullRequest, branchName: branchName)
        }
        .task(id: DescriptionKey(body: pullRequest.body, underlineLinks: underlineLinks)) {
            let document = await MarkdownDocument.parseInBackground(pullRequest.body, underlineLinks: underlineLinks)
            guard !Task.isCancelled else {
                return
            }
            description = ParsedDescription(body: pullRequest.body, underlineLinks: underlineLinks, document: document)
        }
    }

    /// The description parsed for the current body and setting; nil while
    /// it's being parsed.
    private func parsedDescription(underlineLinks: Bool) -> MarkdownDocument? {
        description?.matches(pullRequest.body, underlineLinks: underlineLinks) == true ? description?.document : nil
    }

    private var actions: PullRequestOverviewActions {
        let number = pullRequest.pullRequestNumber
        let worktree = ActionID.newWorktree(branch: pullRequest.head.ref, pullRequest: number)
        return PullRequestOverviewActions(
            checkOut: {
                context.actions.perform(.checkoutPullRequest(number: number))
            },
            checkOutInNewWorktree: context.actions.canPerform(worktree) ? { context.actions.perform(worktree) } : nil,
            open: { url in
                context.app.integrations.openInBrowser(url)
            },
            checks: ChecksListActions(
                open: { url in
                    context.app.integrations.openInBrowser(url)
                },
                rerun: { failedOnly, checkID in
                    RerunChecksSheet.present(repository: repository, pullRequest: pullRequest, failedOnly: failedOnly, checkID: checkID, in: context)
                }
            ),
            checkOutRefusal: context.actions.disabledReason(.checkoutPullRequest(number: number))
        )
    }

    private struct PullRequestKey: Hashable {
        let number: Int
        let branchName: String
    }

    /// The pull request shown, in its repository: the scope of the
    /// overview's motion.
    private struct MotionKey: Hashable {
        let repository: ObjectIdentifier
        let number: Int
    }

    private struct DescriptionKey: Hashable {
        let body: String
        let underlineLinks: Bool
    }

    /// The description, parsed for the body and setting it was parsed
    /// with.
    private struct ParsedDescription {
        let body: String
        let underlineLinks: Bool
        let document: MarkdownDocument

        func matches(_ body: String, underlineLinks: Bool) -> Bool {
            self.body == body && self.underlineLinks == underlineLinks
        }
    }
}

/// The overview: header, actions, checks, and description.
struct PullRequestOverviewView: View {
    let content: PullRequestOverviewContent
    let checks: ChecksContent
    /// The parsed description; nil while it's being parsed.
    let description: MarkdownDocument?
    let actions: PullRequestOverviewActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                header
                buttons
                Hairline()
                checksSection
                Hairline()
                descriptionSection
            }
            .padding(Metrics.insetLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .unbouncedScrollContent()
        }
        .background(Color(nsColor: Palette.background))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                Text(content.title)
                    .font(Typography.commitSummary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if content.isDraft {
                    QuietCapsule("Draft")
                }
            }
            HStack(spacing: Metrics.grid) {
                Text(verbatim: "#\(content.number) opened")
                RelativeTimeText(content.created)
                Text("by")
                Avatar(content.authorAvatar)
                Text(content.author)
            }
            .font(Typography.secondary)
            .foregroundStyle(.text2)
            .accessibilityElement(children: .combine)
            HStack(spacing: Metrics.grid) {
                QuietCapsule(content.base, isName: true)
                Image(systemName: "arrow.left")
                    .font(Typography.subheadline)
                    .foregroundStyle(.text2)
                    .accessibilityLabel("from")
                QuietCapsule(content.head, isName: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(content.head) into \(content.base)")
        }
    }

    /// Check Out (or "Checked Out"), View on GitHub, and Check Out in New
    /// Worktree…, on a second line when the column is too narrow for them.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.insetSmall) {
                checkOutButtons
                worktreeButton
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                HStack(spacing: Metrics.insetSmall) {
                    checkOutButtons
                }
                worktreeButton
            }
        }
    }

    /// Check Out, the area's prominent button, or the plain "Checked Out"
    /// when it's the current branch's pull request; and View on GitHub.
    @ViewBuilder
    private var checkOutButtons: some View {
        if content.isCurrentBranch {
            Text("Checked Out")
                .font(Typography.row)
                .foregroundStyle(.text2)
                .fixedSize()
        } else {
            Button("Check Out", action: actions.checkOut)
                .buttonStyle(.prominent)
                .disabled(actions.checkOutRefusal != nil)
                .fixedSize()
                .tooltip(actions.checkOutRefusal)
        }
        if let url = content.url {
            Button(content.viewOnGitHubTitle) {
                actions.open(url)
            }
            .buttonStyle(.quiet)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var worktreeButton: some View {
        if let checkOutInNewWorktree = actions.checkOutInNewWorktree {
            Button("Check Out in New Worktree…", action: checkOutInNewWorktree)
                .buttonStyle(.quiet)
                .fixedSize()
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            SectionLabel("Checks")
            if !checks.isEmpty, !(checks.isLoading && checks.overall == nil) {
                ChecksHeader(content: checks, actions: actions.checks)
            }
            ChecksList(content: checks, actions: actions.checks)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            SectionLabel("Description")
            if let description {
                if description.isEmpty {
                    Text("No description provided.")
                        .foregroundStyle(.text2)
                } else {
                    MarkdownView(document: description)
                }
            }
        }
    }
}

// MARK: The changes

/// The pull request's changes since the merge base, or why they can't
/// show.
struct PullRequestChangesView: View {
    let repository: RepositoryModel
    let pullRequest: PullRequest
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = repository.history.pullRequestChanges
        Group {
            if changes.pullRequest != pullRequest {
                DelayedProgressView()
            } else {
                switch changes.status {
                case .idle, .loading:
                    DelayedProgressView()
                case .changesNotAvailable, .noBaseBranch:
                    CenteredMessage(
                        "Changes Not Available",
                        systemImage: "doc.text.magnifyingglass",
                        description: "Check out this pull request to see its changes."
                    ) {
                        let checkOut = ActionID.checkoutPullRequest(number: pullRequest.pullRequestNumber)
                        let refusal = context.actions.disabledReason(checkOut)
                        Button("Check Out") {
                            context.actions.perform(checkOut)
                        }
                        .buttonStyle(.quiet)
                        .disabled(refusal != nil)
                        .tooltip(refusal)
                    }
                case .failed(let error):
                    CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                case .loaded:
                    if let empty = changes.emptyMessage {
                        CenteredMessage(empty.title, systemImage: "arrow.trianglehead.pull", description: empty.message)
                    } else {
                        PullRequestFilesAndDiff(changes: changes, repository: repository, pullRequest: pullRequest)
                    }
                }
            }
        }
        // The background fills the pane, whatever the state's size.
        .fillingSpace()
        .background(Color(nsColor: Palette.background))
        .task(id: pullRequest) {
            if changes.pullRequest != pullRequest || changes.status == .idle {
                await changes.showChanges(of: pullRequest)
            }
        }
        .onChange(of: repository.gitState.branches.all.map(\.tip.sha)) {
            // A fetch or checkout may have brought the head commit.
            if changes.pullRequest == pullRequest, changes.status == .changesNotAvailable {
                Task {
                    await changes.showChanges(of: pullRequest)
                }
            }
        }
    }
}

/// The changed files beside the selected file's diff. When the toolbar
/// search hides the selected file, the first file it lists is selected, or
/// none when it lists none (`filteredSelection`).
private struct PullRequestFilesAndDiff: View {
    let changes: PullRequestPreviewModel
    let repository: RepositoryModel
    let pullRequest: PullRequest
    @Environment(WindowContext.self) private var context

    var body: some View {
        SplitView(autosaveName: "Espalier.Split.pullRequestFiles", leadingColumn: Metrics.Column.commitFileList) {
            ChangedFilesList(
                selection: changes.selection,
                repositoryPath: repository.record.path,
                filter: context.state.searchText,
                menuContent: { file in
                    PullRequestFileMenus.pullRequest(file, pullRequest, changes: changes, repositoryPath: repository.record.path)
                }
            ) { file in
                changes.selectFile(file)
            }
        } trailing: {
            DiffContainer(changes.selection.diff, file: changes.selection.file.map(DiffFileInfo.init), context: .pullRequest)
        }
        .onChange(of: searchedFileIDs, initial: true) {
            selectSearchedFile()
        }
    }

    /// The IDs of the files the search lists, once they've loaded; nil
    /// without a search.
    private var searchedFileIDs: [String]? {
        let filter = context.state.searchText
        guard !filter.isEmpty, let files = changes.selection.changeset.value?.files else {
            return nil
        }
        return ChangedFilesList.files(files, filter: filter).map(\.id)
    }

    /// Keeps the selected file to those the search lists, as a click
    /// selects (`filteredSelection`).
    private func selectSearchedFile() {
        guard let listed = searchedFileIDs, let files = changes.selection.changeset.value?.files,
              let kept = filteredSelection(changes.selection.file.map { [$0.id] } ?? [], listed: listed)
        else {
            return
        }
        changes.selectFile(kept.first.flatMap { id in files.first { $0.id == id } })
    }
}

/// A changed file, as the pull request's lists show it.
nonisolated struct ChangedFileRowContent: Sendable, Equatable, Identifiable {
    var id: String
    var path: String
    var oldPath: String?
    var status: FileStatusKind

    init(id: String, path: String, oldPath: String? = nil, status: FileStatusKind) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.status = status
    }

    init(_ file: CommittedFileChange) {
        self.init(id: file.id, path: file.path, oldPath: file.status.oldPath, status: FileStatusKind(file.status))
    }

    var fileName: String {
        POSIXPath.basename(path)
    }

    var directory: String {
        let directory = POSIXPath.dirname(path)
        return directory == "." ? "" : directory
    }
}

/// The files a pull request (or its preview) changes: the count and the
/// lines added and removed, then the files matching the filter, with a
/// file menu (Show in Finder, Open in the editor, Open with Default App,
/// Copy File Path, Copy Relative File Path, View on GitHub) and a
/// double-click that opens the file in the editor.
struct ChangedFilesList: View {
    let selection: CommitSelection
    /// The repository's working tree, which the files' paths are in.
    var repositoryPath: String?
    /// The toolbar search's text, in a pull request's place.
    var filter: String = ""
    /// A file's menu; nil offers none.
    var menuContent: ((CommittedFileChange) -> CommittedFileMenuContent)?
    let select: (CommittedFileChange?) -> Void
    @Environment(WindowContext.self) private var context

    var body: some View {
        VStack(spacing: 0) {
            if let changeset = selection.changeset.value {
                let files = Self.files(changeset.files, filter: filter)
                ChangedFilesHeader(
                    title: ChangesHeaderContent.title(
                        fileCount: changeset.files.count,
                        visibleCount: files.count,
                        numberFormat: context.app.preferences.numberFormat
                    ),
                    linesAdded: changeset.linesAdded,
                    linesDeleted: changeset.linesDeleted
                )
                Hairline()
                if files.isEmpty && !filter.isEmpty {
                    CenteredMessage("No Matching Files", systemImage: "magnifyingglass", description: "No changed files match \u{201C}\(filter)\u{201D}.")
                        .fillingSpace()
                } else {
                    List(selection: Binding(
                        get: { selection.file?.id },
                        set: { id in
                            select(id.flatMap { id in changeset.files.first { $0.id == id } })
                        }
                    )) {
                        ForEach(files, id: \.id) { file in
                            ChangedFileRow(content: ChangedFileRowContent(file))
                                .selectableRow(isSelected: file.id == selection.file?.id, showsSelectionBar: true)
                                .contextMenuRow(file.id)
                                .tag(file.id)
                                .listRowInsets(Metrics.ListRow.insets(isFirst: file.id == files.first?.id, isLast: file.id == files.last?.id))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .unbouncedList()
                    .contextMenuCard(forSelectionType: String.self, selection: selection.file.map { [$0.id] } ?? []) { [context, menuContent] ids in
                        if let menuContent, let id = ids.first, let file = changeset.files.first(where: { $0.id == id }) {
                            CommittedFileContextMenu.content(menuContent(file), context: context)
                        }
                    } primaryAction: { ids in
                        if let repositoryPath, let id = ids.first, let file = changeset.files.first(where: { $0.id == id }) {
                            context.actions.perform(.openInEditor(path: POSIXPath.join(repositoryPath, file.path)))
                        }
                    }
                }
            } else if let error = selection.changeset.failure {
                CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                    .fillingSpace()
            } else {
                DelayedProgressView()
            }
        }
    }
}

extension ChangedFilesList {
    /// The files matching `filter` (their path, ignoring case).
    static func files(_ files: [CommittedFileChange], filter: String) -> [CommittedFileChange] {
        files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }
}

/// The pull request file lists' menus: View on GitHub opens the file at
/// the newest commit, once it's on GitHub.
enum PullRequestFileMenus {
    /// Preview Pull Request's: at the newest commit once it's been pushed,
    /// in the repository's GitHub repository.
    static func preview(_ file: CommittedFileChange, repository: RepositoryModel) -> CommittedFileMenuContent {
        CommittedFileMenuContent(
            file,
            repositoryPath: repository.record.path,
            commit: repository.history.pullRequestPreview.nonLocalCommitSHA,
            in: repository.record.gitHubRepository
        )
    }

    /// A pull request's place: at its head commit, which GitHub has (in the
    /// base repository, which shows a fork's commits too), once its changes
    /// are loaded.
    static func pullRequest(_ file: CommittedFileChange, _ pullRequest: PullRequest, changes: PullRequestPreviewModel, repositoryPath: String) -> CommittedFileMenuContent {
        let isLoaded = changes.pullRequest == pullRequest && changes.commits.first?.sha == pullRequest.head.sha
        return CommittedFileMenuContent(
            file,
            repositoryPath: repositoryPath,
            commit: isLoaded ? pullRequest.head.sha : nil,
            in: pullRequest.base.gitHubRepository
        )
    }
}

/// "3 changed files", or "0 of 3 changed files" while the search hides
/// some, and the lines added and removed ("+12 −4", zero counts left out).
struct ChangedFilesHeader: View {
    let title: String
    let linesAdded: Int
    let linesDeleted: Int

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Text(title)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .lineLimit(1)
            Spacer(minLength: Metrics.grid)
            if linesAdded > 0 || linesDeleted > 0 {
                HistoryLineCounts(added: linesAdded, deleted: linesDeleted)
            }
        }
        .padding(.horizontal, Metrics.insetMedium)
        .padding(.vertical, Metrics.insetSmall)
    }
}

/// One changed file: its status, name, and folder.
struct ChangedFileRow: View {
    let content: ChangedFileRowContent

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            StatusGlyph(content.status)
            Text(content.fileName)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !content.directory.isEmpty {
                Text(content.directory)
                    .font(Typography.subheadline)
                    .foregroundStyle(.text2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .tooltip(content.oldPath.map { "\($0) → \(content.path)" } ?? content.path)
        .accessibilityElement(children: .combine)
    }
}
