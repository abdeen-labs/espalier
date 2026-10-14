// Ported in part from desktop/app/src/ui/create-branch/create-branch-dialog.tsx
//
// New Branch… (⇧⌘N), Create Branch from Commit, and Cherry-pick to New
// Branch use the sheet.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

// MARK: - Name checks

/// What's wrong with a proposed branch name, or how it will be changed.
nonisolated public struct BranchNameValidation: Sendable, Equatable {
    /// A message under the name field.
    public enum Message: Sendable, Equatable {
        /// The name can't be used.
        case error(String)
        /// The name can be used; this is worth knowing.
        case warning(String)

        public var text: String {
            switch self {
            case .error(let text), .warning(let text): text
            }
        }

        public var isError: Bool {
            if case .error = self { true } else { false }
        }
    }

    /// The name as git will have it: spaces and invalid characters replaced
    /// by hyphens (`sanitizedRefName`).
    public let sanitizedName: String
    public let messages: [Message]

    /// Whether the name can be used.
    public var isValid: Bool {
        !JSCompat.trim(sanitizedName).isEmpty && !messages.contains(where: \.isError)
    }

    /// Checks `proposed` against the repository's branches.
    ///
    /// - Parameters:
    ///   - verb: How the warning names what happens to the name ("Will be
    ///     created as …").
    ///   - currentName: A rename's current name, which the new name may
    ///     keep.
    public static func validate(_ proposed: String, branches: [Branch], verb: String = "created", currentName: String? = nil) -> BranchNameValidation {
        let sanitized = sanitizedRefName(proposed)
        var messages: [Message] = []
        if proposed.isEmpty {
            return BranchNameValidation(sanitizedName: sanitized, messages: [])
        }
        if sanitized.isEmpty {
            messages.append(.error("\(proposed) is not a valid name."))
            return BranchNameValidation(sanitizedName: sanitized, messages: messages)
        }
        if !JSCompat.strictEquals(proposed, sanitized) {
            messages.append(.warning("Will be \(verb) as \(sanitized)."))
        }
        let isCurrentName = currentName.map { JSCompat.strictEquals($0, sanitized) } ?? false
        if !isCurrentName, branches.contains(where: { JSCompat.strictEquals($0.name, sanitized) }) {
            messages.append(.error("A branch named \(sanitized) already exists."))
        } else if currentName == nil,
                  branches.contains(where: { $0.type == .remote && JSCompat.strictEquals($0.nameWithoutRemote, sanitized) }) {
            messages.append(.warning("A branch named \(sanitized) already exists on the remote."))
        }
        return BranchNameValidation(sanitizedName: sanitized, messages: messages)
    }

    /// The validation with what the repository's rules say about the name
    /// (`checkBranchNameRules`): a rule the user can't bypass is an error,
    /// one they can bypass a warning.
    public func adding(_ ruleError: BranchNameRuleError?) -> BranchNameValidation {
        guard let ruleError else {
            return self
        }
        let message: Message = ruleError.isWarning ? .warning(ruleError.message) : .error(ruleError.message)
        return BranchNameValidation(sanitizedName: sanitizedName, messages: messages + [message])
    }
}

/// Asks the repository's rules about a branch name, 500 ms after typing
/// stops, and keeps the answer for the name it was asked about.
struct BranchNameRuleCheck: Equatable {
    var name: String
    var error: BranchNameRuleError?

    /// The debounce.
    static let delay: Duration = .milliseconds(500)

    /// The rules' answer for `validation`'s name, when it's known.
    static func applying(_ check: BranchNameRuleCheck?, to validation: BranchNameValidation) -> BranchNameValidation {
        guard let check, JSCompat.strictEquals(check.name, validation.sanitizedName) else {
            return validation
        }
        return validation.adding(check.error)
    }

    /// Checks `validation`'s name after the debounce, unless the name
    /// already can't be used.
    static func run(
        _ validation: BranchNameValidation,
        with checker: (@MainActor (String) async -> BranchNameRuleError?)?
    ) async -> BranchNameRuleCheck? {
        guard let checker, validation.isValid else {
            return nil
        }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else {
            return nil
        }
        let error = await checker(validation.sanitizedName)
        return Task.isCancelled ? nil : BranchNameRuleCheck(name: validation.sanitizedName, error: error)
    }
}

// MARK: - Content

/// What the New Branch sheet is for.
nonisolated public enum NewBranchSheetMode: Sendable, Equatable {
    /// New Branch…: from the default branch or the current one.
    case create(initialName: String)
    /// From a commit (Create Branch from Commit), or another start point
    /// such as a tag.
    case startPoint(String, summary: String?)
    /// Cherry-pick to New Branch: the branch is made from a start point the
    /// user picks, then the commits are copied to it.
    case cherryPick(shas: [String], initialName: String = "")

    public static let create = NewBranchSheetMode.create(initialName: "")

    var initialName: String {
        switch self {
        case .create(let name), .cherryPick(_, let name): name
        case .startPoint: ""
        }
    }
}

/// What the new branch will be based on, as the sheet explains it.
nonisolated public enum NewBranchBase: Sendable, Equatable {
    /// A commit or another start point (Create Branch from Commit).
    case startPoint(name: String, summary: String?)
    /// HEAD is detached: the new branch starts at its commit.
    case detached(sha: String)
    /// The current branch is unborn: creating renames it.
    case unborn
    /// Only the current branch; `isDefault` when it's the default branch.
    case currentBranch(name: String, isDefault: Bool)
    /// A fork whose current branch is the parent's default branch.
    case upstreamDefault(name: String, repositoryName: String)
    /// A choice between the (upstream) default branch and the current one.
    case choice([NewBranchBaseOption])
}

/// One start point the sheet offers.
nonisolated public struct NewBranchBaseOption: Sendable, Equatable, Identifiable {
    public var startPoint: StartPoint
    public var title: String
    public var description: String

    public var id: String {
        startPoint.rawValue
    }
}

/// What the New Branch sheet shows.
nonisolated public struct NewBranchSheetContent: Sendable, Equatable {
    public var title: String
    public var confirmButton: String
    public var base: NewBranchBase
    /// The start point chosen first.
    public var initialStartPoint: StartPoint
    /// Whether the fork behavior link shows (forks only).
    public var showsForkBehaviorLink: Bool

    /// The sheet for `mode` in a repository with this state.
    public static func make(
        mode: NewBranchSheetMode,
        tip: Tip,
        defaultBranch: Branch?,
        upstreamDefaultBranch: Branch?,
        upstreamRepositoryName: String?,
        isFork: Bool
    ) -> NewBranchSheetContent {
        let startPoint = getStartPoint(
            BranchInfo(tip: tip, defaultBranch: defaultBranch, upstreamDefaultBranch: upstreamDefaultBranch),
            .upstreamDefaultBranch
        )
        let title: String
        let confirmButton: String
        switch mode {
        case .cherryPick:
            title = "Cherry-pick to New Branch"
            confirmButton = "Create Branch and Cherry-pick"
        case .create, .startPoint:
            title = "Create a Branch"
            confirmButton = "Create Branch"
        }

        let base: NewBranchBase
        switch (mode, tip) {
        case (.startPoint(let name, let summary), _):
            base = .startPoint(name: name, summary: summary)
        case (_, .detached(let sha)):
            base = .detached(sha: sha)
        case (_, .unborn), (_, .unknown):
            base = .unborn
        case (_, .valid(let current)):
            if let upstreamDefaultBranch, let upstreamRepositoryName {
                // we assume here that the upstream and this fork will have
                // the same default branch name
                if JSCompat.strictEquals(current.name, upstreamDefaultBranch.nameWithoutRemote) {
                    base = .upstreamDefault(name: upstreamDefaultBranch.nameWithoutRemote, repositoryName: upstreamRepositoryName)
                } else {
                    base = .choice([
                        NewBranchBaseOption(
                            startPoint: .upstreamDefaultBranch,
                            title: upstreamDefaultBranch.name,
                            description: "The default branch of the upstream repository. Pick this to start on something new that's not dependent on your current branch."
                        ),
                        currentOption(current.name),
                    ])
                }
            } else if let defaultBranch, !JSCompat.strictEquals(defaultBranch.name, current.name) {
                base = .choice([
                    NewBranchBaseOption(
                        startPoint: .defaultBranch,
                        title: defaultBranch.name,
                        description: "The default branch in your repository. Pick this to start on something new that's not dependent on your current branch."
                    ),
                    currentOption(current.name),
                ])
            } else {
                base = .currentBranch(name: current.name, isDefault: defaultBranch != nil)
            }
        }

        var initial = startPoint
        if case .choice(let options) = base, !options.contains(where: { $0.startPoint == startPoint }) {
            initial = .currentBranch
        }
        return NewBranchSheetContent(
            title: title,
            confirmButton: confirmButton,
            base: base,
            initialStartPoint: initial,
            showsForkBehaviorLink: isFork
        )
    }

    private static func currentOption(_ name: String) -> NewBranchBaseOption {
        NewBranchBaseOption(
            startPoint: .currentBranch,
            title: name,
            description: "The currently checked out branch. Pick this if you need to build on work done on this branch."
        )
    }

    /// The sentence explaining the base, when there's no choice.
    public var baseExplanation: String? {
        switch base {
        case .startPoint(let name, let summary?):
            return "Your new branch will be based on the commit '\(summary)' (\(JSCompat.prefix(name, 7))) from your repository."
        case .startPoint(let name, nil):
            // A commit History hasn't loaded (a tag's): its short SHA.
            if name.count == 40, name.allSatisfy(\.isHexDigit) {
                return "Your new branch will be based on the commit \(JSCompat.prefix(name, 7))."
            }
            return "Your new branch will be based on \(name)."
        case .detached(let sha):
            return "You're on a detached HEAD, not a branch, so your new branch will be based on the checked-out commit (\(JSCompat.prefix(sha, 7)))."
        case .unborn:
            return "Your current branch has no commits yet, so creating a new branch renames it."
        case .currentBranch(let name, let isDefault):
            let base = "Your new branch will be based on your currently checked out branch (\(name))."
            return isDefault ? "\(base) \(name) is the default branch for your repository." : base
        case .upstreamDefault(let name, let repositoryName):
            return "Your new branch will be based on \(repositoryName)'s default branch (\(name))."
        case .choice:
            return nil
        }
    }

    /// The sheet for a repository.
    @MainActor
    static func make(mode: NewBranchSheetMode, repository: RepositoryModel) -> NewBranchSheetContent {
        let state = repository.gitState
        let record = repository.record
        let upstream = isForkedRepositoryContributingToParent(record) ? record.gitHubRepository?.parent?.fullName : nil
        return make(
            mode: mode,
            tip: state.tip,
            defaultBranch: state.branches.defaultBranch,
            upstreamDefaultBranch: upstream == nil ? nil : state.branches.upstreamDefaultBranch,
            upstreamRepositoryName: upstream,
            isFork: isRepositoryWithForkedGitHubRepository(record)
        )
    }
}

// MARK: - The sheet

/// The New Branch sheet: a name, what it's based on, and Create Branch.
public struct NewBranchSheet: View {
    static let sheetID = "espalier.newBranch"

    private let content: NewBranchSheetContent
    private let branches: [Branch]
    private let checkRules: (@MainActor (String) async -> BranchNameRuleError?)?
    private let onCreate: (_ name: String, _ startPoint: StartPoint) -> Void
    private let onForkBehavior: (() -> Void)?
    @State private var name: String
    @State private var startPoint: StartPoint
    @State private var ruleCheck: BranchNameRuleCheck?
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismissModal) private var dismissModal

    /// - Parameters:
    ///   - branches: The repository's branches, for the name checks.
    ///   - checkRules: Asks the repository's rules about a name
    ///     (`checkBranchNameRules`), or nil.
    ///   - onCreate: Creates the branch (the sheet has closed).
    ///   - onForkBehavior: Opens Repository Settings at Fork Behavior.
    public init(
        _ content: NewBranchSheetContent,
        initialName: String = "",
        branches: [Branch],
        checkRules: (@MainActor (String) async -> BranchNameRuleError?)? = nil,
        onCreate: @escaping (_ name: String, _ startPoint: StartPoint) -> Void,
        onForkBehavior: (() -> Void)? = nil
    ) {
        self.content = content
        self.branches = branches
        self.checkRules = checkRules
        self.onCreate = onCreate
        self.onForkBehavior = onForkBehavior
        _name = State(initialValue: initialName)
        _startPoint = State(initialValue: content.initialStartPoint)
    }

    public var body: some View {
        let basic = BranchNameValidation.validate(name, branches: branches)
        let validation = BranchNameRuleCheck.applying(ruleCheck, to: basic)
        SheetScaffold(content.title) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                TextField("Name", text: $name, prompt: Text("Branch name").fieldPrompt())
                    .textFieldStyle(.capsule)
                    .focused($isNameFocused)
                    .onSubmit { create(validation) }
                NameValidationMessages(validation)
            }
            baseView
            if content.showsForkBehaviorLink, let onForkBehavior {
                // The link inside the sentence, so the sentence wraps as one.
                LinkedText(Self.forkBehaviorSentence)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { _ in
                        onForkBehavior()
                        return .handled
                    })
            }
        } buttons: {
            SheetButtons(content.confirmButton, isConfirmDisabled: !validation.isValid, cancel: { dismissModal() }) {
                create(validation)
            }
        }
        .onAppear {
            isNameFocused = true
        }
        .task(id: basic) {
            if let check = await BranchNameRuleCheck.run(basic, with: checkRules) {
                ruleCheck = check
            }
        }
    }

    /// "Your default branch source is determined by your fork behavior
    /// settings.", the settings a link (the URL only marks it: the sheet's
    /// `openURL` opens Repository Settings).
    private static var forkBehaviorSentence: AttributedString {
        var link = AttributedString("fork behavior settings")
        link.link = URL(string: "espalier-settings:fork-behavior")
        return AttributedString("Your default branch source is determined by your ") + link + AttributedString(".")
    }

    @ViewBuilder
    private var baseView: some View {
        if case .choice(let options) = content.base {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Create branch based on…")
                ChoiceList(
                    "Create branch based on…",
                    selection: $startPoint,
                    choices: options.map { ChoiceListItem($0.title, description: $0.description, value: $0.startPoint) }
                )
            }
        } else if let explanation = content.baseExplanation {
            Text(explanation)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func create(_ validation: BranchNameValidation) {
        guard validation.isValid else {
            return
        }
        let name = validation.sanitizedName
        let startPoint = startPoint
        dismissModal()
        onCreate(name, startPoint)
    }

    /// Shows the sheet for `mode` in the window's repository.
    static func present(_ mode: NewBranchSheetMode, in context: WindowContext) {
        guard let repository = context.repository else {
            return
        }
        let content = NewBranchSheetContent.make(mode: mode, repository: repository)
        context.modals.presentSheet(id: sheetID) {
            NewBranchSheet(
                content,
                initialName: mode.initialName,
                branches: repository.gitState.branches.all,
                checkRules: { [weak repository] name in
                    await repository?.gitHub.checkBranchNameRules(name)
                },
                onCreate: { [weak context] name, startPoint in
                    guard let context else {
                        return
                    }
                    Task {
                        await BranchActions.create(name, startPoint: startPoint, mode: mode, in: context)
                    }
                },
                onForkBehavior: { [weak context] in
                    context?.modals.dismissSheet(id: sheetID)
                    context?.actions.perform(.repositorySettings)
                }
            )
        }
    }
}

/// The name field's messages: errors in red, warnings in orange, with
/// their symbols.
struct NameValidationMessages: View {
    let validation: BranchNameValidation

    init(_ validation: BranchNameValidation) {
        self.validation = validation
    }

    var body: some View {
        ForEach(Array(validation.messages.enumerated()), id: \.offset) { _, message in
            Label {
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: message.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            }
            .font(Typography.subheadline)
            .foregroundStyle(Color(espalier: message.isError ? Palette.error : Palette.warning))
            .accessibilityLabel(message.isError ? "Error: \(message.text)" : "Warning: \(message.text)")
        }
    }
}
