// The composer under the Changes list, top to bottom: the last commit with
// Undo, the amend note, the commit message card, an AI failure, one
// warning, the hook line, and the commit button. The card holds the
// summary (with its hints) and the description, the co-authors under them
// while they show, dividers between, a faint accent tint behind the one
// that has focus, and a footer: the AI button, Co-Authors, and Options,
// then the author's avatar. `CommitModel` commits, and the window's
// presenter shows its gates.
//
// While a merge waits on its conflicts, the form shows the merge's message
// (git's, which the user may edit) and its button is Commit Merge; the
// user's draft is set aside, untouched, and shows again once the merge
// ends.

import AIKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Everything the composer shows besides the text the user types.
nonisolated public struct ComposerContent: Sendable, Equatable {
    public var lastCommit: LastCommitContent?
    public var isAmending: Bool
    public var author: AuthorIdentityContent
    /// "Summary (required)", or "Update README.md" with one file.
    public var summaryPlaceholder: String
    /// The lightbulb: the summary is longer than 50 characters.
    public var showsLengthHint: Bool
    /// The commit message fails the branch's message rules.
    public var messageRuleFailures: MessageRuleFailures?
    public var sparkle: SparkleState
    /// The models to choose from, while none is chosen.
    public var modelChoices: [SparkleModelChoice]
    /// The last generation's failure, shown under the fields.
    public var aiFailure: AIFailureContent?
    /// Whether the repository has co-authors (GitHub repositories).
    public var showsCoAuthorsToggle: Bool
    public var isCoAuthorsToggleEnabled: Bool
    public var warning: CommitWarning?
    /// Whether the Options menu shows (not for a merge's commit).
    public var showsCommitOptions: Bool
    public var options: CommitOptionsContent
    public var hook: HookActivityContent?
    public var button: CommitButtonContent
    /// A commit or a generation runs: the fields can't change.
    public var isReadOnly: Bool
    public var isGenerating: Bool
    /// Whether "Check Spelling While Typing" is on.
    public var isSpellCheckingEnabled: Bool
    /// Whether Repository Settings… can open.
    public var canOpenRepositorySettings: Bool

    public init(
        lastCommit: LastCommitContent? = nil,
        isAmending: Bool = false,
        author: AuthorIdentityContent,
        summaryPlaceholder: String = ComposerContent.defaultPlaceholder,
        showsLengthHint: Bool = false,
        messageRuleFailures: MessageRuleFailures? = nil,
        sparkle: SparkleState = .hidden,
        modelChoices: [SparkleModelChoice] = [],
        aiFailure: AIFailureContent? = nil,
        showsCoAuthorsToggle: Bool = false,
        isCoAuthorsToggleEnabled: Bool = true,
        warning: CommitWarning? = nil,
        showsCommitOptions: Bool = true,
        options: CommitOptionsContent = CommitOptionsContent(),
        hook: HookActivityContent? = nil,
        button: CommitButtonContent,
        isReadOnly: Bool = false,
        isGenerating: Bool = false,
        isSpellCheckingEnabled: Bool = true,
        canOpenRepositorySettings: Bool = true
    ) {
        self.lastCommit = lastCommit
        self.isAmending = isAmending
        self.author = author
        self.summaryPlaceholder = summaryPlaceholder
        self.showsLengthHint = showsLengthHint
        self.messageRuleFailures = messageRuleFailures
        self.sparkle = sparkle
        self.modelChoices = modelChoices
        self.aiFailure = aiFailure
        self.showsCoAuthorsToggle = showsCoAuthorsToggle
        self.isCoAuthorsToggleEnabled = isCoAuthorsToggleEnabled
        self.warning = warning
        self.showsCommitOptions = showsCommitOptions
        self.options = options
        self.hook = hook
        self.button = button
        self.isReadOnly = isReadOnly
        self.isGenerating = isGenerating
        self.isSpellCheckingEnabled = isSpellCheckingEnabled
        self.canOpenRepositorySettings = canOpenRepositorySettings
    }

    /// The summary's placeholder when the commit doesn't name one file.
    public static let defaultPlaceholder = "Summary (required)"
}

/// A failed generation, as the line under the fields shows it.
nonisolated public struct AIFailureContent: Sendable, Equatable {
    /// What the line offers.
    public enum Recovery: Sendable, Equatable {
        case tryAgain
        case openSettings
    }

    public var message: String
    public var recovery: Recovery

    public init(message: String, recovery: Recovery) {
        self.message = message
        self.recovery = recovery
    }

    /// The line for an error: Open AI Settings… when the setup is at fault
    /// (fixable errors carry `.openSettings(.ai)`), else Try Again.
    public init(_ error: OperationError) {
        var recovery = Recovery.tryAgain
        switch error.reason {
        case .ai(.noProvider), .ai(.modelSelectionRequired), .ai(.modelUnavailable), .ai(.disabled):
            recovery = .openSettings
        default:
            if error.recoveries.contains(where: { if case .openSettings(.ai) = $0 { true } else { false } }) {
                recovery = .openSettings
            }
        }
        let message = if case .ai(let failure) = error.reason { failure.message } else { error.message }
        self.init(message: message, recovery: recovery)
    }
}

extension ComposerContent {
    /// The composer for a repository: the merge's while a merge waits on
    /// its conflicts (`merge(_:app:actions:button:)`).
    ///
    /// - Parameters:
    ///   - aiFailure: The window's last generation failure.
    ///   - messageRuleFailures: The rules the commit message fails, as last
    ///     checked (`commitMessageRuleFailures()`).
    @MainActor
    public static func make(
        _ repository: RepositoryModel,
        app: AppModel,
        actions: WindowActions? = nil,
        aiFailure: OperationError? = nil,
        messageRuleFailures: MessageRuleFailures? = nil
    ) -> ComposerContent {
        if let slot = OperationSlotContent.make(repository), slot.kind == .merge {
            return merge(repository, app: app, actions: actions, button: slot.button)
        }
        let commit = repository.commit
        let draft = commit.draft
        let state = repository.gitState
        let files = repository.changes.workingDirectory.files
        let included = files.filter { $0.selection.getSelectionType() != .none }
        let isCommitting = repository.localOperation?.kind == .commit
        let isGenerating = repository.ai.commitMessageGeneration == .generating
        let isAmending = commit.amending != nil
        let isGitHub = repository.record.gitHubRepository != nil
        let branch = state.tip.composerBranchName

        // One included file names the commit.
        let placeholder = commit.summaryPlaceholder
        let prepopulate = placeholder != nil
        let summaryOrPlaceholder = prepopulate && draft.summary.isEmpty ? placeholder ?? "" : draft.summary

        // The branch's rules: failing ones disable the button (the commit's
        // gate checks them again).
        let gitHub = repository.gitHub
        var messageFailures: MessageRuleFailures?
        var hasRuleFailure = false
        if gitHub.repoRulesEnabled, let rules = gitHub.repoRules {
            messageFailures = messageRuleFailures
            let branchNameStatus = branch.map { rules.branchNamePatterns.getFailedRules($0).status }
            hasRuleFailure = rules.basicCommitWarning == .enforced
                || rules.signedCommitsRequired == .enforced
                || rules.pullRequestRequired == .enforced
                || messageFailures?.canBypass == false
                || gitHub.commitAuthorRuleFailures.status == .fail
                || (state.aheadBehind == nil && (rules.creationRestricted == .enforced || branchNameStatus == .fail))
        }

        let canCommit = (((!included.isEmpty || commit.options.allowEmpty) && !draft.summary.isEmpty) || prepopulate) && !hasRuleFailure
        let canAmend = isAmending && (!draft.summary.isEmpty || prepopulate) && !hasRuleFailure
        let isSummaryBlank = summaryOrPlaceholder.unicodeScalars.allSatisfy(JSCompat.isWhitespace)
        let isEnabled = (canCommit || canAmend) && !isCommitting && !isSummaryBlank && !isGenerating
        let disabledReason: String? = if isSummaryBlank {
            "Enter a summary to commit"
        } else if included.isEmpty, !files.isEmpty, !commit.options.allowEmpty, !isAmending {
            "Select one or more files to commit"
        } else if isCommitting {
            "Committing changes…"
        } else if files.isEmpty, !commit.options.allowEmpty, !isAmending {
            "There are no changes to commit."
        } else {
            nil
        }

        let sparkle = SparkleState.make(repository, app: app, isCommitting: isCommitting)
        // The model keeps a provider's failure; errors thrown before a
        // request (no model, a refusal) the window keeps.
        var failure = aiFailure
        if case .failed(let error) = repository.ai.commitMessageGeneration {
            failure = error
        }
        let hook: HookActivityContent? = if isCommitting, let activity = repository.localOperation?.hook {
            HookActivityContent(
                hookName: activity.name,
                status: activity.status,
                canShowOutput: repository.localOperation?.terminalOutput != nil
            )
        } else {
            nil
        }

        return ComposerContent(
            lastCommit: LastCommitContent.make(repository),
            isAmending: isAmending,
            author: AuthorIdentityContent.make(repository, app: app),
            summaryPlaceholder: placeholder ?? defaultPlaceholder,
            showsLengthHint: app.preferences.showCommitLengthWarning && messageFailures == nil
                && draft.summary.utf16.count > idealSummaryLength,
            messageRuleFailures: messageFailures,
            sparkle: sparkle,
            modelChoices: sparkle == .chooseModel ? app.ai.availableModels.map(SparkleModelChoice.init) : [],
            aiFailure: sparkle == .hidden ? nil : failure.map(AIFailureContent.init),
            showsCoAuthorsToggle: isGitHub,
            isCoAuthorsToggleEnabled: !isCommitting && !isGenerating,
            warning: CommitWarning.make(repository),
            options: CommitOptionsContent(
                isAmending: isAmending,
                canToggleAmend: commit.canStartAmending && !isCommitting && !isGenerating,
                options: commit.options,
                isEnabled: !isCommitting && !isGenerating
            ),
            hook: hook,
            button: CommitButtonContent(
                isAmending: isAmending,
                fileCount: included.count,
                branch: branch,
                isCommitting: isCommitting,
                isGenerating: isGenerating,
                isEnabled: isEnabled,
                disabledReason: disabledReason,
                numberFormat: app.preferences.numberFormat
            ),
            isReadOnly: isCommitting || isGenerating,
            isGenerating: isGenerating,
            isSpellCheckingEnabled: app.preferences.commitSpellcheckEnabled,
            canOpenRepositorySettings: actions?.canPerform(.repositorySettings) ?? false
        )
    }

    /// The composer while a merge waits on its conflicts: the merge's
    /// message in the fields (`Composer.draft(for:)`), the author, and
    /// Commit Merge; no AI, co-authors, options, last commit, or warnings.
    /// The fields can't change while the merge is committed.
    @MainActor
    static func merge(_ repository: RepositoryModel, app: AppModel, actions: WindowActions?, button: CommitButtonContent) -> ComposerContent {
        let isCommitting = button.isCommitting
        let hook: HookActivityContent? = if isCommitting, let activity = repository.localOperation?.hook {
            HookActivityContent(
                hookName: activity.name,
                status: activity.status,
                canShowOutput: repository.localOperation?.terminalOutput != nil
            )
        } else {
            nil
        }
        return ComposerContent(
            author: AuthorIdentityContent.make(repository, app: app),
            showsCommitOptions: false,
            hook: hook,
            button: button,
            isReadOnly: isCommitting,
            isSpellCheckingEnabled: app.preferences.commitSpellcheckEnabled,
            canOpenRepositorySettings: actions?.canPerform(.repositorySettings) ?? false
        )
    }

    /// Whether the co-authors field shows for `draft`.
    public func showsCoAuthors(_ draft: CommitDraft) -> Bool {
        showsCoAuthorsToggle && draft.showCoAuthoredBy
    }
}

/// What the composer's controls do.
public struct ComposerActions {
    public var commit: () -> Void = {}
    public var undo: () -> Void = {}
    public var stopAmending: () -> Void = {}
    public var toggleAmend: () -> Void = {}
    public var generate: () -> Void = {}
    public var cancelGeneration: () -> Void = {}
    public var chooseModel: (SparkleModelChoice) -> Void = { _ in }
    public var openAISettings: () -> Void = {}
    public var stopHook: () -> Void = {}
    public var openGitSettings: () -> Void = {}
    public var openRepositorySettings: () -> Void = {}
    /// The author warning's Update Email: sets the global email.
    public var updateEmail: (String) -> Void = { _ in }
    /// A warning's link: create a fork, switch branches, or a web page.
    public var openLink: (URL) -> Void = { _ in }
    public var setSpellChecking: (Bool) -> Void = { _ in }

    public init() {}

    /// Nothing happens (snapshots).
    public static let none = ComposerActions()
}

/// The composer, from its content and the draft.
public struct ComposerView: View {
    private let content: ComposerContent
    @Binding private var draft: CommitDraft
    @Binding private var options: CommitOptions
    @Binding private var sparklePopover: SparklePopover?
    private let hookOutput: TerminalOutputListener?
    private let completions: ComposerCompletions
    private let focusRequest: Int
    private let actions: ComposerActions

    @State private var focusBridge = ComposerFocusBridge()
    @Environment(\.motion) private var motion
    @Environment(\.appearsActive) private var appearsActive

    /// - Parameters:
    ///   - draft: The commit message being written.
    ///   - options: The commit options.
    ///   - sparklePopover: The sparkle's popover, when it shows.
    ///   - hookOutput: The commit's live terminal output.
    ///   - completions: `@` and `#` completions and co-author lookups.
    ///   - focusRequest: Changes when the summary should take focus (Go to
    ///     Commit Message).
    public init(
        _ content: ComposerContent,
        draft: Binding<CommitDraft>,
        options: Binding<CommitOptions> = .constant(CommitOptions()),
        sparklePopover: Binding<SparklePopover?> = .constant(nil),
        hookOutput: TerminalOutputListener? = nil,
        completions: ComposerCompletions = .none,
        focusRequest: Int = 0,
        actions: ComposerActions = .none
    ) {
        self.content = content
        _draft = draft
        _options = options
        _sparklePopover = sparklePopover
        self.hookOutput = hookOutput
        self.completions = completions
        self.focusRequest = focusRequest
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            if let lastCommit = content.lastCommit {
                // Grows in after a commit over 0.22 s and leaves over 0.15
                // s (Changes' column sets the motion).
                VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                    LastCommitRow(lastCommit, onUndo: actions.undo)
                    Hairline()
                }
                .barTransition()
            }
            if content.isAmending {
                // Grows in over 0.22 s and leaves over 0.15 s (Changes'
                // column sets the motion).
                AmendBanner(onStopAmending: actions.stopAmending)
                    .barTransition()
            }
            card
            if let failure = content.aiFailure {
                AIFailureLine(failure, onTryAgain: actions.generate, onOpenSettings: actions.openAISettings)
            }
            if let warning = content.warning {
                CommitWarningView(warning, onLink: actions.openLink)
            }
            if let hook = content.hook {
                HookActivityView(hook, output: hookOutput, onStop: actions.stopHook)
            }
            CommitButton(content.button, action: actions.commit)
        }
        .padding(.horizontal, Metrics.Composer.horizontalPadding)
        .padding(.top, Metrics.insetMedium)
        .padding(.bottom, Metrics.Composer.horizontalPadding)
        .onChange(of: focusRequest) {
            focusBridge.focusSummary()
        }
        .onKeyPress(.escape) {
            guard content.isGenerating else {
                return .ignored
            }
            actions.cancelGeneration()
            return .handled
        }
    }

    /// The commit message card: the summary (semibold), a divider, and the
    /// description; the co-authors under another divider while they show;
    /// then a footer with the AI button, co-authors, and the commit options
    /// on the left and the author on the right.
    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.insetSmall) {
                SummaryField(
                    summary: summaryBinding,
                    placeholder: content.summaryPlaceholder,
                    isEditable: !content.isReadOnly,
                    isGenerating: content.isGenerating,
                    isSpellCheckingEnabled: content.isSpellCheckingEnabled,
                    completions: completions,
                    menuItems: menuItems,
                    onSpellCheckingChange: actions.setSpellChecking,
                    onSubmit: { focusBridge.focusDescription() },
                    onEscape: cancelGeneration,
                    focusBridge: focusBridge,
                    font: Self.summaryFont
                )
                if let failures = content.messageRuleFailures {
                    MessageRulesHint(failures: failures, onLink: actions.openLink)
                }
                if content.showsLengthHint {
                    SummaryLengthHint()
                }
            }
            .padding(.horizontal, Metrics.Composer.cardPadding)
            .padding(.top, Metrics.Composer.summaryTopPadding)
            .padding(.bottom, Metrics.insetSmall)
            .background {
                focusTint(behind: .summary)
            }
            .fieldRegion()
            Hairline()
                .padding(.horizontal, Metrics.Composer.cardPadding)
            DescriptionEditor(
                text: descriptionBinding,
                isEditable: !content.isReadOnly,
                isSpellCheckingEnabled: content.isSpellCheckingEnabled,
                completions: completions,
                menuItems: menuItems,
                onSpellCheckingChange: actions.setSpellChecking,
                onEscape: cancelGeneration,
                focusBridge: focusBridge,
                textColor: Palette.text2
            )
            .padding(.horizontal, Metrics.Composer.cardPadding)
            .padding(.vertical, Metrics.grid)
            .background {
                focusTint(behind: .description)
            }
            .fieldRegion()
            if content.showsCoAuthors(draft) {
                // Opens and closes as a bar does (`coAuthorsBinding`).
                VStack(spacing: 0) {
                    Hairline()
                        .padding(.horizontal, Metrics.Composer.cardPadding)
                    CoAuthorsField(
                        authors: $draft.coAuthors,
                        isEditable: !content.isReadOnly,
                        completions: completions,
                        focusBridge: focusBridge
                    )
                    .padding(.horizontal, Metrics.Composer.cardPadding)
                    .padding(.vertical, Metrics.grid)
                    .background {
                        focusTint(behind: .coAuthors)
                    }
                    .fieldRegion()
                }
                .barTransition()
            }
            Hairline()
            footer
        }
        .surface(Color(espalier: Palette.background), elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .contextMenuCard {
            for item in menuItems {
                MenuAction(item.title, action: item.action)
                    .disabled(!item.isEnabled)
            }
        }
    }

    /// The field the focus tint shows behind: the one with keyboard focus,
    /// while the window is active and the fields can change.
    private var markedField: ComposerField? {
        guard appearsActive, !content.isReadOnly else {
            return nil
        }
        return focusBridge.focusedField
    }

    /// The faint accent tint over `field`'s whole part of the card while it
    /// has focus, from the card's edges to the dividers; the summary's top
    /// corners are the card's. It fades in over 0.15 s and out over 0.1 s,
    /// and crossfades to the other field.
    private func focusTint(behind field: ComposerField) -> some View {
        let corner = field == .summary ? Metrics.Radius.card : 0
        return ZStack {
            if markedField == field {
                UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner, style: .continuous)
                    .fill(Color(espalier: Palette.accentFaint))
                    .transition(.opacity)
            }
        }
        .animation(motion.animation(markedField == nil ? Motion.focusOut : Motion.leave), value: markedField)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The card's footer: the AI button, co-authors, and the options on the
    /// left, as icon buttons; the author on the right. The commit button
    /// names the branch.
    private var footer: some View {
        HStack(spacing: 0) {
            SparkleButton(content.sparkle, action: actions.generate)
                .popoverCard(item: $sparklePopover, title: sparklePopover?.title) { popover in
                    switch popover {
                    case .setup:
                        AISetupPopover(onOpenSettings: actions.openAISettings)
                    case .chooseModel:
                        AIModelPopover(content.modelChoices, onChoose: actions.chooseModel)
                    }
                }
            if content.showsCoAuthorsToggle {
                // On, the symbol fills in the accent.
                Toggle(isOn: coAuthorsBinding) {
                    Label {
                        Text("Co-Authors")
                    } icon: {
                        Image(systemName: draft.showCoAuthoredBy ? "person.2.fill" : "person.2")
                            .foregroundStyle(draft.showCoAuthoredBy ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.text2))
                    }
                }
                .toggleStyle(.button)
                .buttonStyle(.icon)
                .disabled(!content.isCoAuthorsToggleEnabled)
                .tooltip(draft.showCoAuthoredBy ? "Remove Co-Authors" : "Add Co-Authors")
                .accessibilityLabel("Co-Authors")
            }
            if content.showsCommitOptions {
                CommitOptionsMenu(content.options, onToggleAmend: actions.toggleAmend) { options = $0 }
            }
            Spacer(minLength: Metrics.insetSmall)
            AuthorAvatarButton(
                content.author,
                canOpenRepositorySettings: content.canOpenRepositorySettings,
                onOpenGitSettings: actions.openGitSettings,
                onOpenRepositorySettings: actions.openRepositorySettings,
                onUpdateEmail: actions.updateEmail
            )
        }
        .padding(.leading, Metrics.Composer.footerPadding)
        .padding(.trailing, Metrics.Composer.cardPadding)
        .frame(height: Metrics.Composer.footerHeight)
    }

    /// The fields' context menu items: co-authors, and generating a message.
    private var menuItems: [ComposerMenuItem] {
        var items: [ComposerMenuItem] = []
        if content.showsCoAuthorsToggle {
            let coAuthors = coAuthorsBinding
            items.append(ComposerMenuItem(
                title: draft.showCoAuthoredBy ? "Remove Co-Authors" : "Add Co-Authors",
                isEnabled: content.isCoAuthorsToggleEnabled
            ) {
                coAuthors.wrappedValue.toggle()
            })
        }
        if content.sparkle != .hidden {
            items.append(ComposerMenuItem(
                title: "Generate Commit Message",
                isEnabled: content.sparkle.isEnabled && content.sparkle != .generating,
                action: actions.generate
            ))
        }
        return items
    }

    /// Whether the co-authors field shows. Turning it on or off opens or
    /// closes the field as a bar does: it grows in over 0.22 s and leaves
    /// over 0.15 s, the files above moving with it (the user's change, so
    /// the motion rides on it).
    private var coAuthorsBinding: Binding<Bool> {
        Binding(
            get: { draft.showCoAuthoredBy },
            set: { shows in
                withMotion(motion, shows ? Motion.arrive : Motion.leave) {
                    draft.showCoAuthoredBy = shows
                }
            }
        )
    }

    /// The summary; typing marks the message as the user's.
    private var summaryBinding: Binding<String> {
        Binding(
            get: { draft.summary },
            set: { summary in
                guard summary != draft.summary else {
                    return
                }
                draft.summary = summary
                draft.generatedByAI = false
            }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { draft.description },
            set: { description in
                guard description != draft.description else {
                    return
                }
                draft.description = description
                draft.generatedByAI = false
            }
        )
    }

    /// Escape in the fields: cancels generating, and says whether it did.
    private func cancelGeneration() -> Bool {
        guard content.isGenerating else {
            return false
        }
        actions.cancelGeneration()
        return true
    }

    /// The summary's font: the row font, semibold.
    private static var summaryFont: NSFont {
        AppKitTypography.row(weight: .semibold)
    }
}

/// A failed generation: the reason in red, and Try Again or Open AI
/// Settings….
struct AIFailureLine: View {
    let failure: AIFailureContent
    let onTryAgain: () -> Void
    let onOpenSettings: () -> Void

    init(_ failure: AIFailureContent, onTryAgain: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.failure = failure
        self.onTryAgain = onTryAgain
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityHidden(true)
            // The message takes the room the button leaves before it wraps.
            Text(failure.message)
                .font(Typography.secondary)
                .foregroundStyle(Color(espalier: Palette.error))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch failure.recovery {
            case .tryAgain:
                Button("Try Again", action: onTryAgain)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            case .openSettings:
                Button("Open AI Settings…", action: onOpenSettings)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Couldn't generate a commit message: \(failure.message)")
    }
}

// MARK: - The composer for a repository

/// The composer for a repository: its content from the models, its actions
/// through the window. While a merge waits on its conflicts it edits the
/// merge's message, and its button commits the merge.
struct Composer: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let windowState = ChangesWindowState.of(context)
        let controller = ComposerController(context: context, repository: repository)
        let commit = repository.commit
        ComposerView(
            windowState.composerContent(repository, context: context),
            draft: Self.draft(for: repository),
            options: Binding(get: { commit.options }, set: { commit.options = $0 }),
            sparklePopover: Binding(get: { windowState.sparklePopover }, set: { windowState.sparklePopover = $0 }),
            hookOutput: repository.localOperation?.terminalOutput,
            completions: ComposerCompletions.make(repository, app: context.app),
            focusRequest: context.state.commitMessageFocusRequest,
            actions: Self.isMerging(repository) ? controller.mergeActions : controller.actions
        )
        .task(id: MessageRuleCheck.of(repository)) {
            await windowState.checkMessageRules(repository)
        }
    }

    /// Whether a merge waits on its conflicts: the form is the merge's.
    static func isMerging(_ repository: RepositoryModel) -> Bool {
        if case .merge? = repository.operations.conflictState {
            return true
        }
        return false
    }

    /// The message the composer edits: the user's draft, or while a merge
    /// waits on its conflicts, the merge's message (`mergeMessage`, git's
    /// until edited), which Commit Merge commits. The user's draft is set
    /// aside meanwhile, untouched, and shows again once the merge ends.
    static func draft(for repository: RepositoryModel) -> Binding<CommitDraft> {
        let commit = repository.commit
        let operations = repository.operations
        guard isMerging(repository) else {
            return Binding(get: { commit.draft }, set: { commit.draft = $0 })
        }
        return Binding(
            get: {
                let message = operations.mergeMessage ?? MergeMessage()
                return CommitDraft(summary: message.summary, description: message.description)
            },
            set: { draft in
                // Before git's message loads, an empty one stays unset, so
                // the load fills it.
                let current = operations.mergeMessage ?? MergeMessage()
                var message = current
                message.summary = draft.summary
                message.description = draft.description
                if message != current {
                    operations.mergeMessage = message
                }
            }
        )
    }
}

/// The Changes place's per-window state that outlives its views.
@MainActor @Observable
final class ChangesWindowState {
    /// The last generation failure, per repository, until the next try.
    var aiFailures: [RepositoryID: OperationError] = [:]
    /// The rules the commit message fails, per repository, as last checked.
    var messageRuleFailures: [RepositoryID: MessageRuleFailures] = [:]
    /// The sparkle's popover, when it shows (⌥⌘G can open it).
    var sparklePopover: SparklePopover?

    /// The window's state.
    static func of(_ context: WindowContext) -> ChangesWindowState {
        context.state.featureState(ChangesWindowState.self) { ChangesWindowState() }
    }

    /// Checks the commit message against the branch's rules, formatted as
    /// it will be committed (the check runs git for co-author trailers),
    /// when what the check reads changes. A newer check cancels this one.
    func checkMessageRules(_ repository: RepositoryModel) async {
        let failures = await repository.gitHub.commitMessageRuleFailures()
        guard !Task.isCancelled else {
            return
        }
        messageRuleFailures[repository.id] = MessageRuleFailures(
            failures,
            gitHubRepository: repository.record.gitHubRepository,
            branch: repository.gitState.tip.composerBranchName
        )
    }

    /// The composer for `repository` in this window.
    func composerContent(_ repository: RepositoryModel, context: WindowContext) -> ComposerContent {
        ComposerContent.make(
            repository,
            app: context.app,
            actions: context.actions,
            aiFailure: aiFailures[repository.id],
            messageRuleFailures: messageRuleFailures[repository.id]
        )
    }
}

/// Runs the composer's intents through the window: commit, undo, amend,
/// generate, and the settings and links the composer offers.
@MainActor
struct ComposerController {
    let context: WindowContext
    let repository: RepositoryModel

    var windowState: ChangesWindowState {
        ChangesWindowState.of(context)
    }

    var actions: ComposerActions {
        var actions = ComposerActions()
        actions.commit = { Task { await commit() } }
        actions.undo = { Task { await undo() } }
        actions.stopAmending = { repository.commit.stopAmending() }
        actions.toggleAmend = { Task { await toggleAmend() } }
        actions.generate = { Task { await generate() } }
        actions.cancelGeneration = { repository.ai.cancelGeneration() }
        actions.chooseModel = { choice in Task { await choose(choice) } }
        actions.openAISettings = { [context] in
            ChangesWindowState.of(context).sparklePopover = nil
            context.actions.perform(.openSettings(.ai))
        }
        actions.stopHook = { repository.abortRunningHook() }
        actions.openGitSettings = { [context] in context.actions.perform(.openSettings(.git)) }
        actions.openRepositorySettings = { [context] in context.actions.perform(.repositorySettings) }
        actions.updateEmail = { email in Task { await updateEmail(email) } }
        actions.openLink = { url in openLink(url) }
        actions.setSpellChecking = { [context] isOn in context.app.preferences.commitSpellcheckEnabled = isOn }
        return actions
    }

    /// The composer's actions while a merge waits on its conflicts: the
    /// button commits the merge.
    var mergeActions: ComposerActions {
        var actions = self.actions
        actions.commit = { Task { await commitMerge() } }
        return actions
    }

    /// Commits the merge waiting on its conflicts with the message the form
    /// shows: the operation's continue, through the presenter, with its
    /// toast.
    func commitMerge() async {
        await MultiCommitActions.continueOperation(in: context, repository: repository)
    }

    // MARK: Committing

    /// Whether the commit button (and ⌘↩) can commit now.
    var canCommit: Bool {
        windowState.composerContent(repository, context: context).button.isEnabled
    }

    /// Commits through the presenter, which asks the commit's gates. After a
    /// commit the filter's text clears.
    ///
    /// VoiceOver hears "Committing" once git runs (past the gates'
    /// questions), and "Committed to main" when it succeeds, which
    /// interrupts "Committing" after a fast commit. A failure's alert or
    /// sheet speaks for itself.
    func commit() async {
        let repository = repository
        let announcer = context.announcer
        let isAmending = repository.commit.amending != nil
        let branch = repository.gitState.tip.composerBranchName
        let started = Task {
            await Observing.until { repository.localOperation?.kind == .commit }
            if !Task.isCancelled {
                announcer.announce(isAmending ? "Amending last commit" : "Committing", priority: .medium)
            }
        }
        let result = await context.presenter.perform { answers throws(OperationError) in
            try await repository.commit.commit(confirmed: answers.confirmed)
        }
        started.cancel()
        if let result {
            announcer.announce(Self.committedAnnouncement(result, branch: branch))
        }
        if result != nil, context.repository === repository {
            context.state.searchText = ""
        }
    }

    /// What VoiceOver hears when a commit succeeds: "Committed to main",
    /// "Committed" (a detached HEAD), or "Amended last commit".
    static func committedAnnouncement(_ result: CommitResult, branch: String?) -> String {
        if result.amended {
            return "Amended last commit"
        }
        return branch.map { "Committed to \($0)" } ?? "Committed"
    }

    // MARK: Undo and amend

    /// The commit Undo applies to, when it's loaded.
    var undoableCommit: Commit? {
        guard let commit = repository.commit.mostRecentLocalCommit,
              repository.commit.undoableCommitSHA == commit.sha
        else {
            return nil
        }
        return commit
    }

    /// Whether Undo can run now (the row's button).
    var canUndo: Bool {
        undoableCommit != nil && repository.localOperation == nil && repository.networkOperation == nil
    }

    func undo() async {
        guard let commit = undoableCommit else {
            return
        }
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.commit.undo(commit, confirmed: answers.confirmed)
        }
    }

    /// Starts amending the last commit (asking first when it was pushed), or
    /// stops.
    func toggleAmend() async {
        if repository.commit.amending != nil {
            repository.commit.stopAmending()
            return
        }
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.commit.startAmending(confirmed: answers.confirmed)
        }
    }

    // MARK: Generating

    /// What the sparkle does in its state (`app.ai.status(for:)`): shows
    /// setup or the model choice; otherwise generates through the presenter,
    /// which asks before replacing a message, then asks for consent before
    /// the provider's first request. While generating, it cancels. Failures
    /// show under the fields, never in an alert.
    func generate() async {
        let app = context.app
        if repository.ai.commitMessageGeneration == .generating {
            repository.ai.cancelGeneration()
            return
        }
        switch app.ai.status(for: .commitMessageGeneration) {
        case .disabled:
            return
        case .needsProvider:
            windowState.sparklePopover = .setup
            return
        case .needsModelChoice:
            windowState.sparklePopover = .chooseModel
            return
        case .needsConsent, .ready:
            break
        }
        windowState.sparklePopover = nil
        windowState.aiFailures[repository.id] = nil
        repository.ai.dismissGenerationFailure()
        let repository = repository
        let repositoryID = repository.id
        do throws(OperationError) {
            _ = try await context.presenter.performThrowing { answers throws(OperationError) in
                do throws(OperationError) {
                    try await repository.ai.generateCommitMessage(confirmed: answers.confirmed)
                } catch {
                    // The provider's first request: show what's sent, then
                    // try again with the answers given so far.
                    guard case .ai(.consentRequired) = error.reason, let disclosure = app.ai.disclosure(for: .commitMessageGeneration) else {
                        throw error
                    }
                    guard await askConsent(AIConsentContent(disclosure)) else {
                        throw OperationError(.cancelled(.userCancelled), operation: .generateCommitMessage, repositoryID: repositoryID)
                    }
                    app.ai.recordConsent(disclosure.consentIdentifier)
                    try await repository.ai.generateCommitMessage(confirmed: answers.confirmed)
                }
            }
        } catch {
            windowState.aiFailures[repositoryID] = error
        }
    }

    /// Chooses the model for commit messages, then generates.
    func choose(_ choice: SparkleModelChoice) async {
        context.app.ai.select(model: choice.id, for: .commitMessageGeneration)
        windowState.sparklePopover = nil
        await generate()
    }

    /// Shows the consent sheet and waits for the answer (closing it any
    /// other way cancels).
    private func askConsent(_ content: AIConsentContent) async -> Bool {
        let modals = context.modals
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = ConsentAnswer(continuation)
            let sheet = modals.presentSheet(id: ConsentSheet.sheetID, onDismiss: { answer.resume(false) }) {
                ConsentSheet(content) { isConfirmed in
                    answer.resume(isConfirmed)
                }
            }
            if sheet == nil {
                answer.resume(false)
            }
        }
    }

    // MARK: The author

    /// Sets the global email to one of the account's addresses; the
    /// selected repository then reloads its author, which clears the
    /// warning when nothing local overrides the address.
    func updateEmail(_ email: String) async {
        let app = context.app
        await context.presenter.perform { _ throws(OperationError) in
            try await app.setGlobalGitAuthor(name: nil, email: email)
        }
    }

    // MARK: Links

    /// A warning's link: create a fork, open the branch popover, or a web
    /// page in the browser.
    func openLink(_ url: URL) {
        switch url {
        case CommitWarning.createForkURL:
            context.actions.perform(.createFork(repositoryID: repository.id))
        case CommitWarning.switchBranchesURL:
            context.actions.perform(.switchBranch)
        default:
            _ = context.app.integrations.openInBrowser(url)
        }
    }
}

/// Resumes the consent sheet's waiter once, whichever answer comes first.
@MainActor
private final class ConsentAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ isConfirmed: Bool) {
        continuation?.resume(returning: isConfirmed)
        continuation = nil
    }
}
