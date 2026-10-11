// The Suggestions that take the diff's place when there are no local
// changes: the primary suggestion in its order (view the stash, publish the
// repository, publish the branch, pull, push, preview or create a pull
// request), then opening the repository in the editor, in Finder, and on
// GitHub. Every button runs the menu action it names, so it's enabled and
// labeled as the menu item is, and each row shows that item's shortcut as
// a key cap and names its menu in the tooltip.

import EspalierCore
import GitKit
import SwiftUI

/// What the Suggestions show.
nonisolated public struct SuggestionsContent: Sendable, Equatable {
    /// The primary suggestion.
    public enum Primary: Sendable, Equatable {
        /// The current branch has a stash.
        case viewStash
        /// The repository has no remote.
        case publishRepository
        /// The branch has no upstream.
        case publishBranch(branch: String, isGitHub: Bool)
        /// The remote has commits the branch doesn't.
        case pull(branch: String, remote: String, behind: Int, isGitHub: Bool)
        /// The branch has commits or tags to push.
        case push(remote: String, ahead: Int, tags: Int, isGitHub: Bool)
        /// A published GitHub branch with no pull request, not the default
        /// branch: preview or create one, as the user last chose.
        case pullRequest(branch: String, choice: PullRequestSuggestedNextAction)
    }

    public var primary: Primary?
    /// Whether the primary suggestion's action can run now.
    public var isPrimaryEnabled: Bool
    /// "Open in Xcode", or nil when no editor is available (the card hides).
    public var editorTitle: String?
    public var isEditorEnabled: Bool
    public var isFinderEnabled: Bool
    /// Whether the repository is on GitHub (the View on GitHub card).
    public var isGitHub: Bool
    public var isGitHubEnabled: Bool
    /// The user's number format, for counts.
    public var numberFormat: NumberFormat

    public init(
        primary: Primary?,
        isPrimaryEnabled: Bool = true,
        editorTitle: String?,
        isEditorEnabled: Bool = true,
        isFinderEnabled: Bool = true,
        isGitHub: Bool,
        isGitHubEnabled: Bool = true,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.primary = primary
        self.isPrimaryEnabled = isPrimaryEnabled
        self.editorTitle = editorTitle
        self.isEditorEnabled = isEditorEnabled
        self.isFinderEnabled = isFinderEnabled
        self.isGitHub = isGitHub
        self.isGitHubEnabled = isGitHubEnabled
        self.numberFormat = numberFormat
    }
}

/// What a suggestion's button does: the menu action it names.
nonisolated public enum SuggestionAction: Sendable, Hashable {
    case viewStash, publishRepository, publishBranch, pull, push, previewPullRequest, createPullRequest
    case openInEditor, showInFinder, viewOnGitHub

    /// The window action the button runs.
    public var actionID: ActionID {
        switch self {
        case .viewStash: .toggleStashedChanges
        case .publishRepository: .publishRepository
        case .publishBranch: .publishBranch
        case .pull: .pull
        case .push: .push
        case .previewPullRequest: .previewPullRequest
        case .createPullRequest: .createPullRequest
        case .openInEditor: .openInEditor(path: nil)
        case .showInFinder: .showInFinder(path: nil)
        case .viewOnGitHub: .viewOnGitHub
        }
    }
}

/// One suggestion: what it suggests, why, where else it lives, and its
/// button.
nonisolated public struct SuggestionCard: Sendable, Equatable {
    public var title: String
    public var description: String?
    /// Whether "Settings" in the description opens Settings ▸ Integrations.
    public var descriptionLinksToSettings = false
    /// Where the action lives besides here: "Repository menu or ⇧⌘A".
    public var discoverability: String
    public var buttonTitle: String
    /// What the button runs.
    public var action: SuggestionAction
}

extension SuggestionsContent.Primary {
    /// The primary suggestion's card.
    public func card(numberFormat: NumberFormat) -> SuggestionCard {
        switch self {
        case .viewStash:
            return SuggestionCard(
                title: "View your stashed changes",
                description: "You have changes stashed on this branch that you haven't committed yet.",
                discoverability: discoverability(.toggleStashedChanges),
                buttonTitle: "View Stash",
                action: .viewStash
            )
        case .publishRepository:
            return SuggestionCard(
                title: "Publish your repository to GitHub",
                description: "This repository is only on this Mac. Publish it to GitHub to share it and collaborate with others.",
                discoverability: "Always available in the toolbar for local repositories, or \(shortcut(.push))",
                buttonTitle: "Publish Repository",
                action: .publishRepository
            )
        case .publishBranch(let branch, let isGitHub):
            let place = isGitHub ? "GitHub" : "the remote"
            let extra = isGitHub ? ", open a pull request," : ""
            return SuggestionCard(
                title: "Publish your branch",
                description: "The current branch (\(branch)) hasn't been published to \(place) yet. Publish it to share it\(extra) and collaborate with others.",
                discoverability: "Always available in the toolbar, or \(shortcut(.push))",
                buttonTitle: "Publish Branch",
                action: .publishBranch
            )
        case .pull(let branch, let remote, let behind, let isGitHub):
            let commits = behind == 1 ? "a commit" : "commits"
            let verb = behind == 1 ? "doesn't" : "don't"
            return SuggestionCard(
                title: "Pull \(formatNumber(Double(behind), numberFormat)) \(behind == 1 ? "commit" : "commits") from the \(remote) remote",
                description: "The current branch (\(branch)) has \(commits) on \(isGitHub ? "GitHub" : "the remote") that \(verb) exist on this Mac.",
                discoverability: "Always available in the toolbar when there are remote changes, or \(shortcut(.pull))",
                buttonTitle: "Pull \(remote)",
                action: .pull
            )
        case .push(let remote, let ahead, let tags, let isGitHub):
            var kinds: [String] = []
            var counts: [String] = []
            if ahead > 0 {
                kinds.append("commits")
                counts.append(ahead == 1 ? "1 local commit" : "\(formatNumber(Double(ahead), numberFormat)) local commits")
            }
            if tags > 0 {
                kinds.append("tags")
                counts.append(tags == 1 ? "1 tag" : "\(formatNumber(Double(tags), numberFormat)) tags")
            }
            return SuggestionCard(
                title: "Push \(kinds.joined(separator: " and ")) to the \(remote) remote",
                description: "You have \(counts.joined(separator: " and ")) waiting to be pushed to \(isGitHub ? "GitHub" : "the remote").",
                discoverability: "Always available in the toolbar when there are local commits waiting to be pushed, or \(shortcut(.push))",
                buttonTitle: "Push \(remote)",
                action: .push
            )
        case .pullRequest(let branch, .previewPullRequest):
            return SuggestionCard(
                title: "Preview the pull request from your current branch",
                description: "The current branch (\(branch)) is already published to GitHub. Preview the changes a pull request would propose.",
                discoverability: discoverability(.previewPullRequest),
                buttonTitle: "Preview Pull Request",
                action: .previewPullRequest
            )
        case .pullRequest(let branch, .createPullRequest):
            return SuggestionCard(
                title: "Create a pull request from your current branch",
                description: "The current branch (\(branch)) is already published to GitHub. Create a pull request to propose and discuss your changes.",
                discoverability: discoverability(.createPullRequest),
                buttonTitle: "Create Pull Request",
                action: .createPullRequest
            )
        }
    }
}

extension SuggestionsContent {
    /// The editor card ("Open in Xcode"), when an editor is available.
    public var editorCard: SuggestionCard? {
        editorTitle.map { title in
            SuggestionCard(
                title: "Open the repository in your external editor",
                description: "Choose your editor in Settings.",
                descriptionLinksToSettings: true,
                discoverability: discoverability(.openInEditor(path: nil)),
                buttonTitle: title,
                action: .openInEditor
            )
        }
    }

    public var finderCard: SuggestionCard {
        SuggestionCard(
            title: "View the files of your repository in Finder",
            description: nil,
            discoverability: discoverability(.showInFinder(path: nil)),
            buttonTitle: "Show in Finder",
            action: .showInFinder
        )
    }

    /// The View on GitHub card, for repositories on GitHub.
    public var gitHubCard: SuggestionCard? {
        guard isGitHub else {
            return nil
        }
        return SuggestionCard(
            title: "Open the repository page on GitHub in your browser",
            description: nil,
            discoverability: discoverability(.viewOnGitHub),
            buttonTitle: "View on GitHub",
            action: .viewOnGitHub
        )
    }
}

/// "Repository menu or ⇧⌘A": the menu an action is in, and its shortcut.
nonisolated func discoverability(_ action: ActionID) -> String {
    let menu = MenuCatalog.all.first { definition in
        definition.actions.contains { $0.kind == action.kind }
    }?.title
    let shortcut = action.kind.shortcut?.symbols
    switch (menu, shortcut) {
    case (let menu?, let shortcut?): return "\(menu) menu or \(shortcut)"
    case (let menu?, nil): return "\(menu) menu"
    case (nil, let shortcut?): return shortcut
    case (nil, nil): return ""
    }
}

/// An action's shortcut in symbols.
nonisolated private func shortcut(_ kind: ActionKind) -> String {
    kind.shortcut?.symbols ?? ""
}

extension SuggestionsContent {
    /// The Suggestions for a repository with no local changes. Buttons are
    /// enabled as their menu items are.
    @MainActor
    public static func make(_ repository: RepositoryModel, app: AppModel, actions: WindowActions) -> SuggestionsContent {
        let primary = primarySuggestion(repository, app: app)
        let isGitHub = repository.record.gitHubRepository != nil
        let editorTitle: String? = app.integrations.isEditorAvailable ? actions.title(for: .openInEditor(path: nil)) : nil
        return SuggestionsContent(
            primary: primary,
            isPrimaryEnabled: primary.map { actions.canPerform($0.card(numberFormat: app.preferences.numberFormat).action.actionID) } ?? false,
            editorTitle: editorTitle,
            isEditorEnabled: actions.canPerform(.openInEditor(path: nil)),
            isFinderEnabled: actions.canPerform(.showInFinder(path: nil)),
            isGitHub: isGitHub,
            isGitHubEnabled: actions.canPerform(.viewOnGitHub),
            numberFormat: app.preferences.numberFormat
        )
    }

    /// The primary suggestion: the branch's stash, else what the remote
    /// calls for. None until the repository's status, remotes, and refs
    /// have loaded: a repository just selected may have only what its
    /// sidebar indicator loaded, without its remotes, which would read as
    /// a repository to publish.
    @MainActor
    static func primarySuggestion(_ repository: RepositoryModel, app: AppModel) -> Primary? {
        let state = repository.gitState
        guard state.hasLoadedRemoteState, case .valid(let branch) = state.tip else {
            return nil
        }
        if repository.stash.current != nil {
            return .viewStash
        }
        guard let remote = state.remotes.currentRemote else {
            return .publishRepository
        }
        let isGitHub = repository.record.gitHubRepository != nil
        guard let aheadBehind = state.aheadBehind else {
            return .publishBranch(branch: branch.name, isGitHub: isGitHub)
        }
        // After a rebase, pulling would bring the old commits back: nothing
        // is suggested until the force push.
        if repository.operations.forcePushState == .recommended {
            return nil
        }
        if aheadBehind.behind > 0 {
            return .pull(branch: branch.name, remote: remote.name, behind: aheadBehind.behind, isGitHub: isGitHub)
        }
        let tags = repository.branches.tagsToPush.count
        if aheadBehind.ahead > 0 || tags > 0 {
            return .push(remote: remote.name, ahead: aheadBehind.ahead, tags: tags, isGitHub: isGitHub)
        }
        let isDefaultBranch = state.branches.defaultBranch?.name == branch.name
        if isGitHub, repository.gitHub.currentPullRequest == nil, !isDefaultBranch {
            return .pullRequest(branch: branch.name, choice: app.preferences.pullRequestSuggestedNextAction)
        }
        return nil
    }
}

extension SuggestionAction {
    /// The row's symbol (the toolbar's, where it has one).
    var systemImage: String {
        switch self {
        case .viewStash: "tray.full"
        case .publishRepository: "icloud.and.arrow.up"
        case .publishBranch: "arrow.up.circle"
        case .pull: "arrow.down.circle"
        case .push: "arrow.up.circle"
        case .previewPullRequest, .createPullRequest: "arrow.trianglehead.pull"
        case .openInEditor: "arrow.up.forward.app"
        case .showInFinder: "folder"
        case .viewOnGitHub: "safari"
        }
    }

    /// The action's shortcut, as a key cap shows it.
    var shortcut: String? {
        actionID.kind.shortcut?.symbols
    }
}

extension SuggestionsContent {
    /// The line under "No Local Changes": what's left to do, which the
    /// primary suggestion says, or the general note without one.
    public var subtitle: String {
        primary?.card(numberFormat: numberFormat).description
            ?? "There are no uncommitted changes in this repository. Here are some suggestions for what to do next."
    }
}

/// The Suggestions: a green check in a soft circle, "No Local Changes", a
/// line about what's left to do, then the suggestions as rows in one card:
/// the primary one with its prominent action, then the editor, Finder, and
/// GitHub, each with its shortcut as a key cap.
public struct NoChangesSuggestions: View {
    private let content: SuggestionsContent
    private let perform: (SuggestionAction) -> Void
    private let onChoosePullRequestAction: (PullRequestSuggestedNextAction) -> Void
    private let onOpenIntegrationSettings: () -> Void

    /// - Parameters:
    ///   - perform: Runs a card's action.
    ///   - onChoosePullRequestAction: Remembers whether the pull request card
    ///     previews or creates.
    ///   - onOpenIntegrationSettings: Opens Settings ▸ Integrations.
    public init(
        _ content: SuggestionsContent,
        perform: @escaping (SuggestionAction) -> Void = { _ in },
        onChoosePullRequestAction: @escaping (PullRequestSuggestedNextAction) -> Void = { _ in },
        onOpenIntegrationSettings: @escaping () -> Void = {}
    ) {
        self.content = content
        self.perform = perform
        self.onChoosePullRequestAction = onChoosePullRequestAction
        self.onOpenIntegrationSettings = onOpenIntegrationSettings
    }

    public var body: some View {
        ScrollView {
            CenteredMessage(
                "No Local Changes",
                systemImage: "checkmark",
                description: content.subtitle,
                tint: Color(espalier: Palette.success),
                isLarge: true
            ) {
                rows
                    .frame(maxWidth: SuggestionMetrics.listWidth)
                    .padding(.top, Metrics.insetSmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, SuggestionMetrics.topInset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(espalier: Palette.background))
    }

    /// The suggestions as rows in one card, hairlines between them.
    private var rows: some View {
        VStack(spacing: 0) {
            let secondary = secondaryCards
            if let primary = content.primary {
                primaryRow(primary)
                if !secondary.isEmpty {
                    Hairline()
                }
            }
            ForEach(Array(secondary.enumerated()), id: \.offset) { index, item in
                SuggestionRow(item.card, isEnabled: item.isEnabled, perform: perform)
                    .environment(\.openURL, OpenURLAction { _ in
                        onOpenIntegrationSettings()
                        return .handled
                    })
                if index < secondary.count - 1 {
                    Hairline()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .surface(.quiet, elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }

    /// The editor, Finder, and GitHub, with whether each can run.
    private var secondaryCards: [(card: SuggestionCard, isEnabled: Bool)] {
        var cards: [(card: SuggestionCard, isEnabled: Bool)] = []
        if let card = content.editorCard {
            cards.append((card, content.isEditorEnabled))
        }
        cards.append((content.finderCard, content.isFinderEnabled))
        if let card = content.gitHubCard {
            cards.append((card, content.isGitHubEnabled))
        }
        return cards
    }

    @ViewBuilder
    private func primaryRow(_ primary: SuggestionsContent.Primary) -> some View {
        let card = primary.card(numberFormat: content.numberFormat)
        if case .pullRequest(_, let choice) = primary {
            SuggestionRow(card, isEnabled: content.isPrimaryEnabled, isProminent: true, perform: perform) {
                SplitCapsuleButton(.prominent, menuLabel: "Pull Request Options", action: { perform(card.action) }) {
                    Text(card.buttonTitle)
                } menu: { [onChoosePullRequestAction] in
                    MenuPicker(selection: Binding(get: { choice }, set: { onChoosePullRequestAction($0) })) {
                        for action in PullRequestSuggestedNextAction.allCases {
                            MenuChoice(action.title, value: action)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(!content.isPrimaryEnabled)
            }
        } else {
            SuggestionRow(card, isEnabled: content.isPrimaryEnabled, isProminent: true, perform: perform)
        }
    }
}

extension PullRequestSuggestedNextAction {
    /// The choice's title.
    nonisolated public var title: String {
        switch self {
        case .previewPullRequest: "Preview Pull Request"
        case .createPullRequest: "Create Pull Request"
        }
    }
}

/// The Suggestions' sizes.
enum SuggestionMetrics {
    /// The action list's width.
    static let listWidth: CGFloat = 440
    /// A row's height on one line.
    static let rowHeight: CGFloat = 48
    /// Space inside a row before its symbol and after its shortcut.
    static let rowPadding: CGFloat = 14
    /// Space above the check.
    static let topInset: CGFloat = 80
    /// A row's symbol column.
    static let symbolWidth: CGFloat = 18
}

/// One suggestion's row: its symbol, its title (and a description, when it
/// has one), its action, and its shortcut as a key cap. The primary row
/// has a prominent button (or a custom control); the others are buttons
/// themselves. The menu the action is in shows as the tooltip.
struct SuggestionRow<Control: View>: View {
    let card: SuggestionCard
    let isEnabled: Bool
    let isProminent: Bool
    let perform: (SuggestionAction) -> Void
    let control: Control?
    @State private var isHovered = false

    init(_ card: SuggestionCard, isEnabled: Bool, isProminent: Bool = false, perform: @escaping (SuggestionAction) -> Void, @ViewBuilder control: () -> Control) {
        self.card = card
        self.isEnabled = isEnabled
        self.isProminent = isProminent
        self.perform = perform
        self.control = control()
    }

    var body: some View {
        if isProminent {
            content
                .tooltip(card.discoverability)
                .accessibilityElement(children: .contain)
        } else {
            // The whole row runs the action; a description's link stays
            // clickable on top.
            ZStack {
                Button {
                    perform(card.action)
                } label: {
                    Color(nsColor: isHovered && isEnabled ? Palette.hover : .clear)
                        .hoverMotion(isHovered)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
                .disabled(!isEnabled)
                .onHover { isHovered = $0 }
                .accessibilityLabel(card.buttonTitle)
                .tooltip(card.discoverability)
                content
                    .allowsHitTesting(card.descriptionLinksToSettings)
                    .accessibilityHidden(card.description == nil)
            }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: Metrics.insetMedium) {
            Image(systemName: card.action.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(isProminent ? Color.accentColor : .text2)
                .frame(width: SuggestionMetrics.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.grid / 2) {
                Text(isProminent ? card.title : card.buttonTitle)
                    .font(isProminent ? Typography.row.weight(.semibold) : Typography.row)
                    .foregroundStyle(.text)
                    .allowsHitTesting(false)
                if !isProminent, let description = card.description {
                    descriptionText(description)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.insetSmall)
            if isProminent {
                if let control {
                    control
                } else {
                    Button(card.buttonTitle) { perform(card.action) }
                        .buttonStyle(.prominent)
                        .controlSize(.small)
                        .disabled(!isEnabled)
                }
            }
            if let shortcut = card.action.shortcut {
                KeyCap(shortcut)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, SuggestionMetrics.rowPadding)
        .padding(.vertical, Metrics.insetSmall)
        .frame(minHeight: SuggestionMetrics.rowHeight)
        .opacity(isProminent || isEnabled ? 1 : Palette.disabledOpacity)
    }

    /// The description, with "Settings" as a link when the card links it.
    private func descriptionText(_ description: String) -> some View {
        var attributed = AttributedString(description)
        if card.descriptionLinksToSettings, let range = description.range(of: "Settings"), let linkRange = Range(range, in: attributed) {
            attributed[linkRange].link = URL(string: "espalier-settings:integrations")
        }
        return LinkedText(attributed)
    }
}

extension SuggestionRow where Control == EmptyView {
    init(_ card: SuggestionCard, isEnabled: Bool, isProminent: Bool = false, perform: @escaping (SuggestionAction) -> Void) {
        self.card = card
        self.isEnabled = isEnabled
        self.isProminent = isProminent
        self.perform = perform
        control = nil
    }
}
