// Every action a menu, the toolbar, a context menu, or another feature can
// ask the window for, with its title and shortcut.

import EspalierCore
import GitKit
import SwiftUI

/// The Debug menu's benchmarks.
nonisolated public enum BenchmarkID: String, CaseIterable, Sendable {
    case historyScroll, diffOpen, changesApply

    public var title: String {
        switch self {
        case .historyScroll: "History Scroll Benchmark"
        case .diffOpen: "Diff Open Benchmark"
        case .changesApply: "Changes Apply Benchmark"
        }
    }
}

/// An action, with its arguments. Arguments left nil mean "the current
/// one": the current branch, the selected commits, the selected file.
///
/// Features register handlers per `ActionKind` (`WindowActions`); menus,
/// buttons, and other features call `actions.perform(_:)`.
nonisolated public enum ActionID: Sendable {
    // MARK: Espalier and Help menus
    case about
    case installCommandLineTool
    case reportIssue
    case showKeyboardShortcuts
    case showLogsInFinder
    /// Opens Settings at a pane (nil: the last one).
    case openSettings(SettingsPane?)

    // MARK: File
    /// "New Repository…", optionally prefilled with a folder.
    case newRepository(path: String?)
    case addLocalRepository
    /// "Clone Repository…", optionally prefilled with a URL.
    case cloneRepository(url: String?)
    /// Folders dropped on the window or the Dock icon.
    case addRepositories(paths: [String])

    // MARK: Edit
    /// ⌘⌫ on the focused list's selection (discard, delete, remove).
    case deleteSelection
    /// Copies the focused selection's absolute path (⌥⌘C).
    case copyPath

    // MARK: View
    case showChanges
    case showHistory
    /// Changes from History and elsewhere, History from Changes (⌃⇥).
    case showNextPlace
    /// History from Changes and elsewhere, Changes from History (⇧⌃⇥).
    case showPreviousPlace
    case selectPlace(SidebarPlace)
    case toggleSidebar
    case filterSidebar
    case search
    case toggleInspector
    case toggleSplitDiff
    case toggleHideWhitespace
    case toggleWrapLines
    case setImageDiffType(ImageDiffType)
    /// View ▸ History: the scope.
    case setHistoryScope(HistoryScope)
    case toggleStashedChanges
    case increaseCodeTextSize
    case decreaseCodeTextSize
    case resetCodeTextSize

    // MARK: Go
    case goBack
    case goForward
    case goToCommit(sha: String?)
    case goToFirstParent
    case goToSecondParent
    case goToChild

    // MARK: Repository
    case push
    case forcePush
    case pull
    case fetch
    case publishRepository
    case publishBranch
    case stashAllChanges
    case discardAllChanges
    case switchRepository
    case repositorySettings
    /// "Create Alias…" or "Change Alias…".
    case changeAlias(RepositoryID?)
    case removeAlias(RepositoryID?)
    case removeRepository(RepositoryID?)
    case openInEditor(path: String?)
    case openWith(path: String?)
    case openInTerminal(path: String?)
    case showInFinder(path: String?)
    /// Opens a file in its default app.
    case openWithDefaultProgram(path: String)
    case viewOnGitHub
    case createIssueOnGitHub
    /// "New Worktree…", or "Check Out in New Worktree…" for a branch (its
    /// name; a remote branch's full name) or a pull request (its head's
    /// remote branch, once fetched, and its number, which names the
    /// worktree).
    case newWorktree(branch: String?, pullRequest: Int? = nil)
    case showWorktrees
    case switchToWorktree(path: String)
    case renameWorktree(path: String)
    case deleteWorktree(path: String)

    // MARK: Branch
    case switchBranch
    case newBranch(startPoint: String?)
    case renameBranch(name: String?)
    case deleteBranch(name: String?)
    case updateFromDefaultBranch
    case compareToBranch(name: String?)
    case mergeIntoCurrentBranch(branch: String?)
    case squashAndMergeIntoCurrentBranch(branch: String?)
    case rebaseCurrentBranch(onto: String?)
    case compareOnGitHub
    case viewBranchOnGitHub(name: String?)
    case previewPullRequest
    /// "Create Pull Request", or "View Pull Request on GitHub" when the
    /// branch has one.
    case createPullRequest
    case checkoutBranch(name: String)
    case copyBranchName(name: String?)
    case restorePrunedBranch(name: String)

    // MARK: Commit
    case commitChanges
    case generateCommitMessage
    case goToCommitMessage
    case toggleAmendLastCommit
    case undoCommit
    case resetToCommit(sha: String?)
    case revertCommit(sha: String?)
    case checkoutCommit(sha: String?)
    case createBranchFromCommit(sha: String?)
    case createTag(sha: String?)
    case deleteTag(name: String)
    case cherryPick(shas: [String]?, target: String?)
    case squash(shas: [String]?, into: String?)
    case reorder(shas: [String]?, before: String?)
    case copySHA(shas: [String]?)
    case viewCommitOnGitHub(sha: String?)

    // MARK: Stashes
    case restoreStash(branch: String?)
    case discardStash(branch: String?)

    // MARK: GitHub, accounts, and recoveries
    /// Signs in (device flow) to an endpoint (nil: GitHub.com), then runs
    /// `then`.
    case signIn(endpoint: String?, then: (any RetryableOperation)?)
    case createFork(repositoryID: RepositoryID)
    case reviewPushProtection(repositoryID: RepositoryID, secrets: [SecretScanResult])
    case checkoutPullRequest(number: Int)
    case viewPullRequestOnGitHub(number: Int?)

    // MARK: Operations
    /// "View Conflicts": Changes, where the conflicts are.
    case showConflicts
    /// "Review Changes": Changes, with the composer focused.
    case reviewChanges

    // MARK: Debug
    case runBenchmark(BenchmarkID)
    /// Checks the menu bar's shortcuts (`MenuBarAudit`).
    case checkMenuShortcuts
    /// Posts a sample pull request notification for the selected
    /// repository's first open pull request.
    case postSampleNotification

    /// The action's kind, which handlers are registered for.
    public var kind: ActionKind {
        switch self {
        case .about: .about
        case .installCommandLineTool: .installCommandLineTool
        case .reportIssue: .reportIssue
        case .showKeyboardShortcuts: .showKeyboardShortcuts
        case .showLogsInFinder: .showLogsInFinder
        case .openSettings: .openSettings
        case .newRepository: .newRepository
        case .addLocalRepository: .addLocalRepository
        case .cloneRepository: .cloneRepository
        case .addRepositories: .addRepositories
        case .deleteSelection: .deleteSelection
        case .copyPath: .copyPath
        case .showChanges: .showChanges
        case .showHistory: .showHistory
        case .showNextPlace: .showNextPlace
        case .showPreviousPlace: .showPreviousPlace
        case .selectPlace: .selectPlace
        case .toggleSidebar: .toggleSidebar
        case .filterSidebar: .filterSidebar
        case .search: .search
        case .toggleInspector: .toggleInspector
        case .toggleSplitDiff: .toggleSplitDiff
        case .toggleHideWhitespace: .toggleHideWhitespace
        case .toggleWrapLines: .toggleWrapLines
        case .setImageDiffType: .setImageDiffType
        case .setHistoryScope: .setHistoryScope
        case .toggleStashedChanges: .toggleStashedChanges
        case .increaseCodeTextSize: .increaseCodeTextSize
        case .decreaseCodeTextSize: .decreaseCodeTextSize
        case .resetCodeTextSize: .resetCodeTextSize
        case .goBack: .goBack
        case .goForward: .goForward
        case .goToCommit: .goToCommit
        case .goToFirstParent: .goToFirstParent
        case .goToSecondParent: .goToSecondParent
        case .goToChild: .goToChild
        case .push: .push
        case .forcePush: .forcePush
        case .pull: .pull
        case .fetch: .fetch
        case .publishRepository: .publishRepository
        case .publishBranch: .publishBranch
        case .stashAllChanges: .stashAllChanges
        case .discardAllChanges: .discardAllChanges
        case .switchRepository: .switchRepository
        case .repositorySettings: .repositorySettings
        case .changeAlias: .changeAlias
        case .removeAlias: .removeAlias
        case .removeRepository: .removeRepository
        case .openInEditor: .openInEditor
        case .openWith: .openWith
        case .openInTerminal: .openInTerminal
        case .showInFinder: .showInFinder
        case .openWithDefaultProgram: .openWithDefaultProgram
        case .viewOnGitHub: .viewOnGitHub
        case .createIssueOnGitHub: .createIssueOnGitHub
        case .newWorktree: .newWorktree
        case .showWorktrees: .showWorktrees
        case .switchToWorktree: .switchToWorktree
        case .renameWorktree: .renameWorktree
        case .deleteWorktree: .deleteWorktree
        case .switchBranch: .switchBranch
        case .newBranch: .newBranch
        case .renameBranch: .renameBranch
        case .deleteBranch: .deleteBranch
        case .updateFromDefaultBranch: .updateFromDefaultBranch
        case .compareToBranch: .compareToBranch
        case .mergeIntoCurrentBranch: .mergeIntoCurrentBranch
        case .squashAndMergeIntoCurrentBranch: .squashAndMergeIntoCurrentBranch
        case .rebaseCurrentBranch: .rebaseCurrentBranch
        case .compareOnGitHub: .compareOnGitHub
        case .viewBranchOnGitHub: .viewBranchOnGitHub
        case .previewPullRequest: .previewPullRequest
        case .createPullRequest: .createPullRequest
        case .checkoutBranch: .checkoutBranch
        case .copyBranchName: .copyBranchName
        case .restorePrunedBranch: .restorePrunedBranch
        case .commitChanges: .commitChanges
        case .generateCommitMessage: .generateCommitMessage
        case .goToCommitMessage: .goToCommitMessage
        case .toggleAmendLastCommit: .toggleAmendLastCommit
        case .undoCommit: .undoCommit
        case .resetToCommit: .resetToCommit
        case .revertCommit: .revertCommit
        case .checkoutCommit: .checkoutCommit
        case .createBranchFromCommit: .createBranchFromCommit
        case .createTag: .createTag
        case .deleteTag: .deleteTag
        case .cherryPick: .cherryPick
        case .squash: .squash
        case .reorder: .reorder
        case .copySHA: .copySHA
        case .viewCommitOnGitHub: .viewCommitOnGitHub
        case .restoreStash: .restoreStash
        case .discardStash: .discardStash
        case .signIn: .signIn
        case .createFork: .createFork
        case .reviewPushProtection: .reviewPushProtection
        case .checkoutPullRequest: .checkoutPullRequest
        case .viewPullRequestOnGitHub: .viewPullRequestOnGitHub
        case .showConflicts: .showConflicts
        case .reviewChanges: .reviewChanges
        case .runBenchmark: .runBenchmark
        case .checkMenuShortcuts: .checkMenuShortcuts
        case .postSampleNotification: .postSampleNotification
        }
    }
}

extension ActionID {
    /// The menu title when the state doesn't change it: the kind's, or the
    /// choice's for actions that pick one.
    nonisolated public var defaultTitle: String {
        switch self {
        case .setImageDiffType(let type): type.title
        case .setHistoryScope(let scope): scope.title
        case .runBenchmark(let benchmark): benchmark.title
        default: kind.title
        }
    }
}

extension ImageDiffType {
    /// The mode's name.
    nonisolated public var title: String {
        switch self {
        case .twoUp: "2-Up"
        case .swipe: "Swipe"
        case .onionSkin: "Onion Skin"
        case .difference: "Difference"
        }
    }
}

/// The kind of an `ActionID`, without its arguments: what handlers are
/// registered for.
nonisolated public enum ActionKind: String, CaseIterable, Sendable {
    case about, installCommandLineTool, reportIssue, showKeyboardShortcuts, showLogsInFinder, openSettings
    case newRepository, addLocalRepository, cloneRepository, addRepositories
    case deleteSelection, copyPath
    case showChanges, showHistory, showNextPlace, showPreviousPlace, selectPlace, toggleSidebar, filterSidebar, search, toggleInspector
    case toggleSplitDiff, toggleHideWhitespace, toggleWrapLines, setImageDiffType, setHistoryScope
    case toggleStashedChanges, increaseCodeTextSize, decreaseCodeTextSize, resetCodeTextSize
    case goBack, goForward, goToCommit, goToFirstParent, goToSecondParent, goToChild
    case push, forcePush, pull, fetch, publishRepository, publishBranch
    case stashAllChanges, discardAllChanges, switchRepository, repositorySettings
    case changeAlias, removeAlias, removeRepository
    case openInEditor, openWith, openInTerminal, showInFinder, openWithDefaultProgram, viewOnGitHub, createIssueOnGitHub
    case newWorktree, showWorktrees, switchToWorktree, renameWorktree, deleteWorktree
    case switchBranch, newBranch, renameBranch, deleteBranch, updateFromDefaultBranch, compareToBranch
    case mergeIntoCurrentBranch, squashAndMergeIntoCurrentBranch, rebaseCurrentBranch
    case compareOnGitHub, viewBranchOnGitHub, previewPullRequest, createPullRequest
    case checkoutBranch, copyBranchName, restorePrunedBranch
    case commitChanges, generateCommitMessage, goToCommitMessage, toggleAmendLastCommit
    case undoCommit, resetToCommit, revertCommit, checkoutCommit, createBranchFromCommit, createTag, deleteTag
    case cherryPick, squash, reorder, copySHA, viewCommitOnGitHub
    case restoreStash, discardStash
    case signIn, createFork, reviewPushProtection, checkoutPullRequest, viewPullRequestOnGitHub
    case showConflicts, reviewChanges
    case runBenchmark, checkMenuShortcuts, postSampleNotification

    /// The menu title when the state doesn't change it (macOS title case).
    public var title: String {
        switch self {
        case .about: "About Espalier"
        case .installCommandLineTool: "Install Command Line Tool…"
        case .reportIssue: "Report Issue…"
        case .showKeyboardShortcuts: "Keyboard Shortcuts"
        case .showLogsInFinder: "Show Logs in Finder"
        case .openSettings: "Settings…"
        case .newRepository: "New Repository…"
        case .addLocalRepository: "Add Local Repository…"
        case .cloneRepository: "Clone Repository…"
        case .addRepositories: "Add Repositories"
        case .deleteSelection: "Delete"
        case .copyPath: "Copy Path"
        case .showChanges: "Changes"
        case .showHistory: "History"
        case .showNextPlace: "Next Place"
        case .showPreviousPlace: "Previous Place"
        case .selectPlace: "Show Place"
        case .toggleSidebar: "Show Sidebar"
        case .filterSidebar: "Filter Sidebar"
        case .search: "Search"
        case .toggleInspector: "Show Inspector"
        case .toggleSplitDiff: "Split Diff"
        case .toggleHideWhitespace: "Hide Whitespace Changes"
        case .toggleWrapLines: "Wrap Lines"
        case .setImageDiffType: "Image Diff"
        case .setHistoryScope: "History"
        case .toggleStashedChanges: "Show Stashed Changes"
        case .increaseCodeTextSize: "Bigger"
        case .decreaseCodeTextSize: "Smaller"
        case .resetCodeTextSize: "Actual Size"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .goToCommit: "Go to Commit…"
        case .goToFirstParent: "First Parent"
        case .goToSecondParent: "Second Parent"
        case .goToChild: "Child"
        case .push: "Push"
        case .forcePush: "Force Push…"
        case .pull: "Pull"
        case .fetch: "Fetch"
        case .publishRepository: "Publish Repository…"
        case .publishBranch: "Publish Branch"
        case .stashAllChanges: "Stash All Changes"
        case .discardAllChanges: "Discard All Changes…"
        case .switchRepository: "Switch Repository…"
        case .repositorySettings: "Repository Settings…"
        case .changeAlias: "Create Alias…"
        case .removeAlias: "Remove Alias"
        case .removeRepository: "Remove…"
        case .openInEditor: "Open in External Editor"
        case .openWith: "Open With…"
        case .openInTerminal: "Open in Terminal"
        case .showInFinder: "Show in Finder"
        case .openWithDefaultProgram: "Open with Default App"
        case .viewOnGitHub: "View on GitHub"
        case .createIssueOnGitHub: "Create Issue on GitHub"
        case .newWorktree: "New Worktree…"
        case .showWorktrees: "Show Worktrees"
        case .switchToWorktree: "Switch to Worktree"
        case .renameWorktree: "Rename…"
        case .deleteWorktree: "Delete…"
        case .switchBranch: "Switch Branch…"
        case .newBranch: "New Branch…"
        case .renameBranch: "Rename…"
        case .deleteBranch: "Delete…"
        case .updateFromDefaultBranch: "Update from Default Branch"
        case .compareToBranch: "Compare to Branch…"
        case .mergeIntoCurrentBranch: "Merge into Current Branch…"
        case .squashAndMergeIntoCurrentBranch: "Squash and Merge into Current Branch…"
        case .rebaseCurrentBranch: "Rebase Current Branch…"
        case .compareOnGitHub: "Compare on GitHub"
        case .viewBranchOnGitHub: "View Branch on GitHub"
        case .previewPullRequest: "Preview Pull Request"
        case .createPullRequest: "Create Pull Request"
        case .checkoutBranch: "Check Out"
        case .copyBranchName: "Copy Branch Name"
        case .restorePrunedBranch: "Restore Pruned Branch"
        case .commitChanges: "Commit Changes"
        case .generateCommitMessage: "Generate Commit Message"
        case .goToCommitMessage: "Go to Commit Message"
        case .toggleAmendLastCommit: "Amend Last Commit"
        case .undoCommit: "Undo Commit…"
        case .resetToCommit: "Reset to Commit…"
        case .revertCommit: "Revert Changes in Commit"
        case .checkoutCommit: "Check Out Commit"
        case .createBranchFromCommit: "Create Branch from Commit…"
        case .createTag: "Create Tag…"
        case .deleteTag: "Delete Tag…"
        case .cherryPick: "Cherry-pick Commit…"
        case .squash: "Squash Commits…"
        case .reorder: "Reorder Commit"
        case .copySHA: "Copy SHA"
        case .viewCommitOnGitHub: "View on GitHub"
        case .restoreStash: "Restore"
        case .discardStash: "Discard…"
        case .signIn: "Sign In…"
        case .createFork: "Fork This Repository…"
        case .reviewPushProtection: "Bypass"
        case .checkoutPullRequest: "Check Out"
        case .viewPullRequestOnGitHub: "View Pull Request on GitHub"
        case .showConflicts: "View Conflicts"
        case .reviewChanges: "Review Changes"
        case .runBenchmark: "Run Benchmark"
        case .checkMenuShortcuts: "Check Menu Shortcuts"
        case .postSampleNotification: "Post Sample Pull Request Notification"
        }
    }

    /// The keyboard shortcut, if any.
    public var shortcut: MenuShortcut? {
        switch self {
        case .showChanges: MenuShortcut("1")
        case .showHistory: MenuShortcut("2")
        case .showNextPlace: MenuShortcut(.tab, [.control])
        case .showPreviousPlace: MenuShortcut(.tab, [.control, .shift])
        case .switchRepository: MenuShortcut("t")
        case .switchBranch: MenuShortcut("b")
        case .push: MenuShortcut("p")
        case .pull: MenuShortcut("p", [.command, .shift])
        case .fetch: MenuShortcut("t", [.command, .shift])
        case .newRepository: MenuShortcut("n")
        case .addLocalRepository: MenuShortcut("o")
        case .cloneRepository: MenuShortcut("o", [.command, .shift])
        case .newBranch: MenuShortcut("n", [.command, .shift])
        case .renameBranch: MenuShortcut("r", [.command, .shift])
        case .deleteBranch: MenuShortcut("d", [.command, .shift])
        case .mergeIntoCurrentBranch: MenuShortcut("m", [.command, .shift])
        case .squashAndMergeIntoCurrentBranch: MenuShortcut("h", [.command, .shift])
        case .rebaseCurrentBranch: MenuShortcut("e", [.command, .shift])
        case .updateFromDefaultBranch: MenuShortcut("u", [.command, .shift])
        case .compareToBranch: MenuShortcut("b", [.command, .shift])
        case .compareOnGitHub: MenuShortcut("c", [.command, .shift])
        case .viewBranchOnGitHub: MenuShortcut("b", [.command, .option])
        case .createPullRequest: MenuShortcut("r")
        case .previewPullRequest: MenuShortcut("p", [.command, .option])
        case .stashAllChanges: MenuShortcut("s", [.command, .shift])
        case .toggleSidebar: MenuShortcut("s")
        case .toggleStashedChanges: MenuShortcut("h", [.control])
        case .discardAllChanges: MenuShortcut(.delete, [.command, .shift])
        case .openInEditor: MenuShortcut("a", [.command, .shift])
        case .openWith: MenuShortcut("a", [.command, .option, .shift])
        case .openInTerminal: MenuShortcut("`", [.control])
        case .showInFinder: MenuShortcut("f", [.command, .shift])
        case .createIssueOnGitHub: MenuShortcut("i")
        case .newWorktree: MenuShortcut("w", [.command, .shift])
        case .showWorktrees: MenuShortcut("w", [.command, .option])
        case .repositorySettings: MenuShortcut(",", [.command, .option])
        case .goToCommitMessage: MenuShortcut("j")
        case .viewOnGitHub: MenuShortcut("g", [.command, .option, .shift])
        case .copyPath: MenuShortcut("c", [.command, .option])
        case .deleteSelection: MenuShortcut(.delete)
        case .search: MenuShortcut("f", [.command, .option])
        case .filterSidebar: MenuShortcut("j", [.command, .option])
        case .commitChanges: MenuShortcut(.return)
        case .generateCommitMessage: MenuShortcut("g", [.command, .option])
        case .increaseCodeTextSize: MenuShortcut("=")
        case .decreaseCodeTextSize: MenuShortcut("-")
        case .resetCodeTextSize: MenuShortcut("0")
        case .goBack: MenuShortcut("[")
        case .goForward: MenuShortcut("]")
        case .goToCommit: MenuShortcut("j", [.command, .shift])
        case .goToFirstParent: MenuShortcut(.downArrow, [.command, .option])
        case .goToChild: MenuShortcut(.upArrow, [.command, .option])
        case .goToSecondParent: MenuShortcut(.downArrow, [.command, .option, .shift])
        default: nil
        }
    }

    /// Whether the action needs a selected repository. Repository-scoped
    /// actions are disabled while a confirmation, decision, error, or prompt
    /// is showing.
    public var isRepositoryScoped: Bool {
        switch self {
        case .about, .installCommandLineTool, .reportIssue, .showKeyboardShortcuts, .showLogsInFinder, .openSettings,
             .newRepository, .addLocalRepository, .cloneRepository, .addRepositories,
             .switchRepository, .toggleSidebar, .filterSidebar, .search, .toggleSplitDiff, .toggleHideWhitespace,
             .toggleWrapLines, .setImageDiffType, .increaseCodeTextSize, .decreaseCodeTextSize,
             .resetCodeTextSize, .signIn, .runBenchmark, .checkMenuShortcuts:
            false
        default:
            true
        }
    }
}

/// A menu keyboard shortcut.
nonisolated public struct MenuShortcut: Sendable, Hashable {
    /// The key.
    public enum Key: Sendable, Hashable {
        case character(Character)
        case `return`, delete, tab, upArrow, downArrow
    }

    /// The modifiers.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ character: Character, _ modifiers: Modifiers = [.command]) {
        self.init(.character(character), modifiers)
    }

    /// The shortcut as SwiftUI takes it.
    public var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .return: .return
        case .delete: .delete
        case .tab: .tab
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// The shortcut in symbols, in Apple's modifier order ("⌥⇧⌘G").
    public var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character):
            text += character == "-" ? "−" : String(character).uppercased()
        case .return: text += "↩"
        case .delete: text += "⌫"
        case .tab: text += "⇥"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        }
        return text
    }
}
