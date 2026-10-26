// The menu bar as data, so the menus, the Keyboard Shortcuts sheet, and the
// tests that check every item validates read the same list.

import EspalierCore
import GitKit

/// One entry in a menu.
nonisolated public enum MenuEntry: Sendable {
    /// An item that runs an action.
    case item(ActionID)
    /// An item with a check mark (a setting, a choice).
    case toggle(ActionID)
    case separator
    /// A submenu of items, toggles, and separators.
    case submenu(String, [MenuEntry])

    /// The actions in the entry, submenus included.
    public var actions: [ActionID] {
        switch self {
        case .item(let action), .toggle(let action): [action]
        case .separator: []
        case .submenu(_, let entries): entries.flatMap(\.actions)
        }
    }
}

/// A menu of the menu bar: its title and Espalier's entries in it (standard
/// items, such as Edit's Undo or Window's, are the system's).
nonisolated public struct MenuDefinition: Sendable {
    public let title: String
    public let entries: [MenuEntry]

    /// Every action in the menu.
    public var actions: [ActionID] {
        entries.flatMap(\.actions)
    }
}

/// Espalier's menus.
nonisolated public enum MenuCatalog {
    /// The Espalier menu's items (About; Install Command Line Tool…; the
    /// system adds Settings…, Services, Hide, and Quit).
    public static let espalier = MenuDefinition(title: "Espalier", entries: [
        .item(.about),
        .item(.installCommandLineTool),
    ])

    public static let file = MenuDefinition(title: "File", entries: [
        .item(.newRepository(path: nil)),
        .item(.addLocalRepository),
        .item(.cloneRepository(url: nil)),
    ])

    /// Added after the standard pasteboard items.
    public static let edit = MenuDefinition(title: "Edit", entries: [
        .item(.deleteSelection),
        .item(.copyPath),
    ])

    /// Before the system's sidebar and toolbar items.
    public static let viewPlaces = MenuDefinition(title: "View", entries: [
        .item(.showChanges),
        .item(.showHistory),
        .item(.showNextPlace),
        .item(.showPreviousPlace),
    ])

    /// After the system's inspector items.
    public static let view = MenuDefinition(title: "View", entries: [
        .item(.toggleSidebar),
        .item(.filterSidebar),
        .item(.search),
        .item(.showCommandPalette),
        .separator,
        .toggle(.toggleSplitDiff),
        .toggle(.toggleHideWhitespace),
        .toggle(.toggleWrapLines),
        .submenu("Image Diff", [
            .toggle(.setImageDiffType(.twoUp)),
            .toggle(.setImageDiffType(.swipe)),
            .toggle(.setImageDiffType(.onionSkin)),
            .toggle(.setImageDiffType(.difference)),
        ]),
        .separator,
        .submenu("History", [
            .toggle(.setHistoryScope(.currentBranch)),
            .toggle(.setHistoryScope(.localBranches)),
            .toggle(.setHistoryScope(.allBranches)),
        ]),
        .item(.toggleStashedChanges),
        .separator,
        .item(.increaseCodeTextSize),
        .item(.decreaseCodeTextSize),
        .item(.resetCodeTextSize),
    ])

    public static let go = MenuDefinition(title: "Go", entries: [
        .item(.goBack),
        .item(.goForward),
        .separator,
        .item(.goToCommit(sha: nil)),
        .item(.goToFirstParent),
        .item(.goToSecondParent),
        .item(.goToChild),
    ])

    public static let repository = MenuDefinition(title: "Repository", entries: [
        .item(.push),
        .item(.forcePush),
        .item(.pull),
        .item(.fetch),
        .separator,
        .item(.stashAllChanges),
        .item(.discardAllChanges),
        .separator,
        .item(.switchRepository),
        .item(.repositorySettings),
        .item(.changeAlias(nil)),
        .item(.removeAlias(nil)),
        .item(.removeRepository(nil)),
        .separator,
        .item(.openInEditor(path: nil)),
        .item(.openWith(path: nil)),
        .item(.openInTerminal(path: nil)),
        .item(.showInFinder(path: nil)),
        .separator,
        .item(.viewOnGitHub),
        .item(.createIssueOnGitHub),
        .item(.publishRepository),
        .separator,
        .item(.newWorktree(branch: nil)),
        .item(.showWorktrees),
    ])

    public static let branch = MenuDefinition(title: "Branch", entries: [
        .item(.switchBranch),
        .item(.newBranch(startPoint: nil)),
        .item(.renameBranch(name: nil)),
        .item(.deleteBranch(name: nil)),
        .separator,
        .item(.updateFromDefaultBranch),
        .item(.compareToBranch(name: nil)),
        .item(.mergeIntoCurrentBranch(branch: nil)),
        .item(.squashAndMergeIntoCurrentBranch(branch: nil)),
        .item(.rebaseCurrentBranch(onto: nil)),
        .separator,
        .item(.compareOnGitHub),
        .item(.viewBranchOnGitHub(name: nil)),
        .separator,
        .item(.previewPullRequest),
        .item(.createPullRequest),
    ])

    public static let commit = MenuDefinition(title: "Commit", entries: [
        .item(.commitChanges),
        .item(.generateCommitMessage),
        .item(.goToCommitMessage),
        .toggle(.toggleAmendLastCommit),
        .separator,
        .item(.undoCommit),
        .item(.resetToCommit(sha: nil)),
        .item(.revertCommit(sha: nil)),
        .separator,
        .item(.checkoutCommit(sha: nil)),
        .item(.createBranchFromCommit(sha: nil)),
        .item(.createTag(sha: nil)),
        .item(.cherryPick(shas: nil, target: nil)),
        .item(.squash(shas: nil, into: nil)),
        .item(.reorder(shas: nil, before: nil)),
        .separator,
        .item(.copySHA(shas: nil)),
        .item(.viewCommitOnGitHub(sha: nil)),
    ])

    public static let help = MenuDefinition(title: "Help", entries: [
        .item(.reportIssue),
        .item(.showKeyboardShortcuts),
        .item(.showLogsInFinder),
    ])

    /// The Debug menu: the benchmarks, the menu bar's shortcut check,
    /// and a sample notification for checking notifications without waiting
    /// for GitHub.
    public static let debug = MenuDefinition(
        title: "Debug",
        entries: BenchmarkID.allCases.map { .item(.runBenchmark($0)) } + [
            .separator,
            .item(.checkMenuShortcuts),
            .item(.postSampleNotification),
        ]
    )

    /// Every menu, in menu bar order (the View menu's two parts as one).
    public static let all: [MenuDefinition] = [
        espalier, file, edit,
        MenuDefinition(title: "View", entries: viewPlaces.entries + [.separator] + view.entries),
        go, repository, branch, commit, help,
    ]
}
