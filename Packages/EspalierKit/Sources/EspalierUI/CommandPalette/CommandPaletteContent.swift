// What the command palette (⌘K) lists: the actions the menu bar offers
// that can run now, each with its menu title, shortcut, and check mark;
// the window's other repositories; and the current repository's other
// local branches. They're gathered once as the palette opens
// (`CommandPaletteSources.make(_:)`). With nothing typed, the palette
// shows every action, the File menu's first and the Espalier and Help
// menus' last, then the recent repositories and the default and recent
// branches. A query keeps what matches, best first
// (PaletteMatcher.swift), at most `resultLimit` repositories and branches,
// and orders the sections by their best match, so Return runs the best one
// whichever section it's in.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import Observation

/// What a palette row does.
nonisolated enum CommandPaletteCommand: Sendable {
    /// Runs an action, as its menu item does.
    case action(ActionID)
    /// Switches the window to a repository.
    case repository(RepositoryID)
    /// Checks out a local branch, as the branch list does.
    case branch(name: String)
}

/// One row the palette can show.
nonisolated struct CommandPaletteItem: Identifiable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        /// An action, by its place in `CommandPaletteSources.catalog`.
        case action(Int)
        case repository(RepositoryID)
        /// A branch, by its ref.
        case branch(ExactString)
    }

    let id: ID
    let systemImage: String
    let title: PaletteSearchText
    /// What else a query of several words matches: an action's menu.
    var context: PaletteSearchText?
    /// What trails the title: an action's menu, a repository's owner or
    /// folder.
    var detail: String?
    /// The shortcut in symbols ("⇧⌘N").
    var shortcut: String?
    /// Whether the action's menu item shows a check mark.
    var isChecked = false
    let command: CommandPaletteCommand
}

/// A row of the results: an item and the title's scalars the query matched.
nonisolated struct CommandPaletteRow: Identifiable, Sendable {
    let item: CommandPaletteItem
    var positions: [Int] = []

    var id: CommandPaletteItem.ID {
        item.id
    }
}

/// A section of the results.
nonisolated struct CommandPaletteSection: Identifiable, Sendable {
    nonisolated enum Kind: Int, Sendable, Hashable {
        case actions, repositories, branches

        var title: String {
            switch self {
            case .actions: "Actions"
            case .repositories: "Repositories"
            case .branches: "Branches"
            }
        }
    }

    let kind: Kind
    let rows: [CommandPaletteRow]

    var id: Kind {
        kind
    }
}

/// Everything the palette can list, gathered as it opens.
nonisolated struct CommandPaletteSources: Sendable {
    /// The actions, in `catalog`'s order.
    var actions: [CommandPaletteItem] = []
    /// The other repositories, in the list's order.
    var repositories: [CommandPaletteItem] = []
    /// The repositories shown with nothing typed: the recent ones.
    var recentRepositories: [CommandPaletteItem.ID] = []
    /// The current repository's other local branches.
    var branches: [CommandPaletteItem] = []
    /// The branches shown with nothing typed: the default and recent ones.
    var recentBranches: [CommandPaletteItem.ID] = []

    /// The most repositories, and the most branches, a query lists.
    static let resultLimit = 50

    /// The sections for `query`: with nothing typed, every action and the
    /// recent repositories and branches; else the matches, best first, and
    /// the sections in order of their best match.
    func sections(for query: String) -> [CommandPaletteSection] {
        guard let query = PaletteQuery(query) else {
            let sections = [
                CommandPaletteSection(kind: .actions, rows: actions.map { CommandPaletteRow(item: $0) }),
                CommandPaletteSection(kind: .repositories, rows: Self.rows(recentRepositories, in: repositories)),
                CommandPaletteSection(kind: .branches, rows: Self.rows(recentBranches, in: branches)),
            ]
            return sections.filter { !$0.rows.isEmpty }
        }
        let matched = [
            Self.matches(of: query, in: actions, kind: .actions, limit: nil),
            Self.matches(of: query, in: repositories, kind: .repositories, limit: Self.resultLimit),
            Self.matches(of: query, in: branches, kind: .branches, limit: Self.resultLimit),
        ]
        return matched
            .compactMap { $0 }
            .sorted { lhs, rhs in
                lhs.best != rhs.best ? lhs.best > rhs.best : lhs.section.kind.rawValue < rhs.section.kind.rawValue
            }
            .map(\.section)
    }

    /// `ids`' items, in that order.
    private static func rows(_ ids: [CommandPaletteItem.ID], in items: [CommandPaletteItem]) -> [CommandPaletteRow] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0].map { CommandPaletteRow(item: $0) } }
    }

    /// The items `query` matches, best first (in their order when they
    /// match as well), as a section, with its best match; nil for none.
    private static func matches(
        of query: PaletteQuery,
        in items: [CommandPaletteItem],
        kind: CommandPaletteSection.Kind,
        limit: Int?
    ) -> (section: CommandPaletteSection, best: PaletteMatch)? {
        var found: [(offset: Int, match: PaletteMatch)] = []
        for (offset, item) in items.enumerated() {
            if let match = query.match(item.title, context: item.context) {
                found.append((offset, match))
            }
        }
        found.sort { lhs, rhs in
            lhs.match != rhs.match ? lhs.match > rhs.match : lhs.offset < rhs.offset
        }
        guard let best = found.first?.match else {
            return nil
        }
        let kept = limit.map { found.prefix($0) } ?? found[...]
        let rows = kept.map { CommandPaletteRow(item: items[$0.offset], positions: $0.match.positions) }
        return (CommandPaletteSection(kind: kind, rows: rows), best)
    }
}

// MARK: - Gathering

/// An action where the menu bar offers it: the menu, and the submenu it's
/// in, if any.
nonisolated struct CommandPaletteCatalogEntry: Sendable {
    let action: ActionID
    let menu: String
    let submenu: String?
    /// A check-marked item.
    let isToggle: Bool
}

extension CommandPaletteSources {
    /// Every action the menu bar offers: its menus from File to Commit (and
    /// the Debug menu's in Debug builds), then the Espalier menu's, with
    /// Settings… after its items as the system puts it, and the Help
    /// menu's. The palette's own item is left out.
    static var catalog: [CommandPaletteCatalogEntry] {
        var menus = MenuCatalog.all.filter { $0.title != MenuCatalog.espalier.title && $0.title != MenuCatalog.help.title }
        if DebugMenu.isEnabled {
            menus.append(MenuCatalog.debug)
        }
        menus += [MenuCatalog.espalier, MenuCatalog.help]
        var entries: [CommandPaletteCatalogEntry] = []
        for menu in menus {
            func add(_ entries: [MenuEntry], submenu: String?, into result: inout [CommandPaletteCatalogEntry]) {
                for entry in entries {
                    switch entry {
                    case .item(let action), .toggle(let action):
                        guard action.kind != .showCommandPalette else {
                            continue
                        }
                        var isToggle = false
                        if case .toggle = entry {
                            isToggle = true
                        }
                        result.append(CommandPaletteCatalogEntry(action: action, menu: menu.title, submenu: submenu, isToggle: isToggle))
                    case .submenu(let title, let children):
                        add(children, submenu: title, into: &result)
                    case .separator:
                        break
                    }
                }
            }
            add(menu.entries, submenu: nil, into: &entries)
            if menu.title == MenuCatalog.espalier.title {
                entries.append(CommandPaletteCatalogEntry(action: .openSettings(nil), menu: menu.title, submenu: nil, isToggle: false))
            }
        }
        return entries
    }

    /// The symbol before the actions of `menu`.
    static func systemImage(forMenu menu: String) -> String {
        switch menu {
        case MenuCatalog.espalier.title: "gearshape"
        case MenuCatalog.file.title: "folder.badge.plus"
        case MenuCatalog.edit.title: "pencil"
        case MenuCatalog.view.title: "eye"
        case MenuCatalog.go.title: "arrow.forward"
        case MenuCatalog.repository.title: "book.closed"
        case MenuCatalog.branch.title: "arrow.trianglehead.branch"
        case MenuCatalog.commit.title: "smallcircle.filled.circle"
        case MenuCatalog.help.title: "questionmark.circle"
        default: "ladybug"
        }
    }

    /// What the palette lists in `context`'s window now: the actions that
    /// can run (`WindowActions.canPerform(_:)`), titled and checked as
    /// their menu items are; the other repositories while Switch
    /// Repository… can run; and the current repository's other local
    /// branches while Switch Branch… can.
    @MainActor
    static func make(_ context: WindowContext) -> CommandPaletteSources {
        let actions = context.actions
        var sources = CommandPaletteSources()
        for (index, entry) in catalog.enumerated() where actions.canPerform(entry.action) {
            let path = [entry.menu] + (entry.submenu.map { [$0] } ?? [])
            sources.actions.append(CommandPaletteItem(
                id: .action(index),
                systemImage: systemImage(forMenu: entry.menu),
                title: PaletteSearchText(actions.title(for: entry.action)),
                context: PaletteSearchText(path.joined(separator: " ")),
                detail: path.joined(separator: " ▸ "),
                shortcut: entry.action.kind.shortcut?.symbols,
                isChecked: entry.isToggle && actions.isChecked(entry.action),
                command: .action(entry.action)
            ))
        }

        let app = context.app
        if actions.canPerform(.switchRepository) {
            let current = context.repository?.id
            for record in app.repositories where record.id != current {
                sources.repositories.append(CommandPaletteItem(
                    id: .repository(record.id),
                    systemImage: "folder",
                    title: PaletteSearchText(record.displayName),
                    context: record.gitHubRepository.map { PaletteSearchText("\($0.owner.login) \($0.name)") },
                    detail: RepositoryRowContent.disambiguation(for: record),
                    command: .repository(record.id)
                ))
            }
            sources.recentRepositories = app.recentRepositoryIDs.filter { $0 != current }.map { .repository($0) }
        }

        if actions.canPerform(.switchBranch), let repository = context.repository {
            let gitState = repository.gitState
            let current = gitState.tip.branch.map { ExactString($0.ref) }
            for branch in gitState.branches.all where branch.type == .local && ExactString(branch.ref) != current {
                sources.branches.append(CommandPaletteItem(
                    id: .branch(ExactString(branch.ref)),
                    systemImage: "arrow.trianglehead.branch",
                    title: PaletteSearchText(branch.name),
                    command: .branch(name: branch.name)
                ))
            }
            let recent = ([gitState.branches.defaultBranch].compactMap(\.self) + gitState.branches.recent)
                .filter { $0.type == .local }
                .map { CommandPaletteItem.ID.branch(ExactString($0.ref)) }
            var seen = Set<CommandPaletteItem.ID>()
            sources.recentBranches = recent.filter { seen.insert($0).inserted }
        }
        return sources
    }
}

// MARK: - The palette's state

/// One opening of the palette: what it lists, the query, and the
/// highlighted row. The window holds it while the palette is open
/// (`WindowState.commandPalette`).
@MainActor @Observable
final class CommandPaletteModel: Identifiable {
    let sources: CommandPaletteSources
    /// What's typed. Changing it lists its matches and highlights the
    /// first.
    var query = "" {
        didSet {
            if query != oldValue {
                sections = sources.sections(for: query)
                highlighted = rowIDs.first
                highlightFollowsPointer = false
            }
        }
    }
    private(set) var sections: [CommandPaletteSection]
    /// The highlighted row, which Return runs.
    var highlighted: CommandPaletteItem.ID?
    /// Whether the pointer moved the highlight last: it fades from row to
    /// row under the pointer, as hover does, and moves at once with the
    /// keyboard.
    var highlightFollowsPointer = false

    init(sources: CommandPaletteSources) {
        self.sources = sources
        sections = sources.sections(for: "")
        highlighted = sections.first?.rows.first?.id
    }

    /// The palette for `context`'s window as it is now.
    convenience init(context: WindowContext) {
        self.init(sources: .make(context))
    }

    /// Every row's ID, in order.
    var rowIDs: [CommandPaletteItem.ID] {
        sections.flatMap { $0.rows.map(\.id) }
    }

    /// The highlighted row.
    var highlightedRow: CommandPaletteRow? {
        guard let highlighted else {
            return nil
        }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == highlighted }) {
                return row
            }
        }
        return nil
    }

    /// Moves the highlight `offset` rows, stopping at the ends; from no
    /// highlight, to the first or last row.
    func move(by offset: Int) {
        let rows = rowIDs
        highlightFollowsPointer = false
        guard !rows.isEmpty else {
            return
        }
        guard let highlighted, let index = rows.firstIndex(of: highlighted) else {
            self.highlighted = offset > 0 ? rows.first : rows.last
            return
        }
        self.highlighted = rows[min(max(index + offset, 0), rows.count - 1)]
    }

    /// Highlights the row under the pointer.
    func point(at id: CommandPaletteItem.ID) {
        guard highlighted != id else {
            return
        }
        highlightFollowsPointer = true
        highlighted = id
    }
}
