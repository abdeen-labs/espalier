// Espalier's menu card in each of its states, light and dark: plain items,
// symbols, subtitles, checks, a choice, sections with headers and
// dividers, destructive and disabled items, a submenu's chevron, the
// highlighted row, and a long menu scrolled to its choice; the highlighted
// row in Frost with Iris and Slate and the sections in Pop's Tangerine; a
// list row as a context menu's target; the buttons that open menus,
// closed; and the suggestion list's card.

import AppKit
import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Menus", .captures) @MainActor
struct MenuCaptures {
    private let area = "Menus"

    /// A card of `content`, with the item titled `highlighted` highlighted.
    private func card(_ content: MenuContent, highlighted: String? = nil, scrollHeight: CGFloat? = nil, minimumWidth: CGFloat = 0) -> MenuCard {
        let level = MenuLevel(content: content, minimumWidth: minimumWidth)
        level.highlighted = highlighted.flatMap { title in level.rows.first { $0.item?.title == title }?.id }
        level.scrollHeight = scrollHeight
        return MenuCard(level: level)
    }

    @Test("plain items, with a divider")
    func plain() {
        capture(card(MenuContent {
            MenuAction("Check Out Branch") {}
            MenuAction("Check Out in New Worktree…") {}
            MenuDivider()
            MenuAction("Copy Branch Name") {}
        }), named: "plain", area: area)
    }

    @Test("symbols and subtitles, under a section header")
    func symbolsAndSubtitles() {
        capture(card(MenuContent {
            MenuSection("Fetched 5 minutes ago") {
                MenuAction("Fetch origin", systemImage: "arrow.triangle.2.circlepath", subtitle: "Fetch the latest changes from origin") {}
                MenuAction("Force Push origin…", systemImage: "exclamationmark.arrow.triangle.2.circlepath", subtitle: "Overwrite any changes on origin with your local changes") {}
            }
            MenuSection {
                MenuAction("Fetch failed — Show Details…") {}
            }
        }), named: "symbolsSubtitles", area: area)
    }

    @Test("checks: toggles and a choice, set off by a divider")
    func checks() {
        capture(card(MenuContent {
            MenuPicker(selection: .constant(true)) {
                MenuChoice("Unified", value: false)
                MenuChoice("Split", value: true)
            }
            MenuDivider()
            MenuToggle("Hide Whitespace Changes", isOn: false) {}
            MenuToggle("Wrap Lines", isOn: true) {}
            MenuDivider()
            MenuAction("Expand Whole File") {}
        }), named: "checks", area: area)
    }

    @Test("a choice with descriptions, the current one checked")
    func choiceWithSubtitles() {
        capture(card(MenuContent {
            MenuPicker(selection: .constant(1)) {
                MenuChoice("Create a Merge Commit", value: 0, subtitle: "The commits from feature will be added to main via a merge commit.")
                MenuChoice("Squash and Merge", value: 1, subtitle: "The 3 commits in feature will be combined into one commit in main.")
                MenuChoice("Rebase", value: 2, subtitle: "The 3 commits in feature will be rebased and added to main.")
            }
        }), named: "choiceSubtitles", area: area)
    }

    /// Sections with headers, a destructive item, a disabled one, and a
    /// submenu.
    private var sections: MenuContent {
        MenuContent {
            MenuPicker(selection: .constant("gpt-5")) {
                MenuSection("OpenAI") {
                    MenuChoice("GPT-5", value: "gpt-5")
                    MenuChoice("GPT-5 mini", value: "gpt-5-mini")
                }
                MenuSection("Local") {
                    MenuChoice("Llama 3", value: "llama3")
                }
            }
            MenuDivider()
            Submenu("History Scope") {
                MenuAction("All Branches") {}
            }
            MenuAction("Restore", subtitle: "Switch to feature to restore its stash.") {}.disabled(true)
            MenuAction("Delete…", role: .destructive) {}
        }
    }

    @Test("sections with headers, a destructive item, a disabled one, and a submenu")
    func sectionsDestructiveDisabledSubmenu() {
        capture(card(sections), named: "sectionsDestructiveDisabledSubmenu", area: area)
    }

    @Test("sections with headers, a destructive item, a disabled one, and a submenu, in Pop's Tangerine")
    func sectionsInPop() {
        capture(card(sections), named: "sectionsDestructiveDisabledSubmenu", area: area, look: Look(theme: .pop, palette: .tangerine))
    }

    /// Symbols, a disabled item, and a destructive one.
    private var branchMenu: MenuContent {
        MenuContent {
            MenuAction("Rename…", systemImage: "pencil") {}
            MenuAction("Copy Branch Name", systemImage: "doc.on.doc") {}
            MenuAction("View on GitHub", systemImage: "safari") {}.disabled(true)
            MenuDivider()
            MenuAction("Delete…", systemImage: "trash", role: .destructive) {}
        }
    }

    @Test("the highlighted row, a destructive one highlighted, and a disabled one under the highlight")
    func highlighted() {
        capture(card(branchMenu, highlighted: "Copy Branch Name"), named: "highlighted", area: area)
        capture(card(branchMenu, highlighted: "Delete…"), named: "highlightedDestructive", area: area)
        capture(card(branchMenu, highlighted: "View on GitHub"), named: "highlightedDisabled", area: area)
    }

    @Test("the highlighted row in Frost with Iris and Slate", arguments: [DesignPalette.iris, .slate])
    func highlightedInFrost(_ palette: DesignPalette) {
        capture(card(branchMenu, highlighted: "Copy Branch Name"), named: "highlighted", area: area, look: Look(theme: .frost, palette: palette))
    }

    @Test("a long menu, scrolled to its choice")
    func scrolled() {
        let names = ["Actionscript", "Ada", "Agda", "Android", "Angular", "AppEngine", "AppceleratorTitanium", "ArchLinuxPackages", "Autotools", "Ballerina", "C", "C++", "CakePHP", "CFWheels", "ChefCookbook", "Clojure", "CMake", "CodeIgniter", "CommonLisp", "Composer", "Concrete5", "Coq", "CraftCMS", "CUDA", "D", "Dart", "Delphi", "DM", "Dotnet", "Drupal"]
        capture(card(MenuContent {
            MenuPicker(selection: .constant("Dart")) {
                MenuChoice("None", value: "None")
                MenuDivider()
                for name in names {
                    MenuChoice(name, value: name)
                }
            }
        }, highlighted: "Dart", scrollHeight: 220, minimumWidth: 200), named: "scrolled", area: area)
    }

    @Test("a list row as a context menu's target, unselected and selected")
    func contextTarget() {
        let view = VStack(spacing: 2) {
            Text("README.md")
                .selectableRow(isSelected: false)
            Text("Sources/App.swift")
                .selectableRow(isSelected: true)
        }
        .environment(\.isContextMenuTarget, true)
        .frame(width: 240)
        .padding(Metrics.insetMedium)
        capture(view, named: "contextTarget", area: area)
    }

    @Test("a pull-down, a pop-up, and a split button, closed")
    func closedButtons() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            PullDownButton("Diff Options") {
                MenuAction("Expand Whole File") {}
            } label: {
                Label("Diff Options", systemImage: "ellipsis")
            }
            .buttonStyle(.icon)
            CapsulePopUp("Protocol", selection: .constant("SSH"), title: "SSH") {
                MenuChoice("HTTPS", value: "HTTPS")
                MenuChoice("SSH", value: "SSH")
            }
            .frame(width: Metrics.SettingsWindow.controlWidth)
            SplitCapsuleButton(.prominent, menuLabel: "Merge Options", action: {}) {
                Text("Squash and Merge")
            } menu: {
                MenuAction("Rebase") {}
            }
            .fixedSize()
        }
        .padding(Metrics.insetLarge)
        capture(view, named: "closedButtons", area: area)
    }

    @Test("the suggestion list: suggestions with details, one highlighted; a field's suggestions as wide as it, scrolling past eight")
    func suggestions() {
        let model = SuggestionListModel()
        model.suggestions = [
            Suggestion(title: "@hubot", detail: "Hubot"),
            Suggestion(title: "@monalisa", detail: "Mona Lisa"),
            Suggestion(title: "@octocat"),
            Suggestion(title: "#142", detail: "Crash when the repository has no commits yet, on opening it"),
        ]
        model.highlighted = 1
        capture(SuggestionListCard(model: model), named: "suggestions", area: area)

        let branches = SuggestionListModel()
        branches.suggestions = ["main", "feature/login", "feature/forecast", "fix/crash", "release/2.0", "origin/main", "origin/feature/login", "origin/fix/crash", "origin/release/2.0", "origin/gh-pages"].map { Suggestion(title: $0) }
        branches.minimumWidth = 280
        capture(SuggestionListCard(model: branches), named: "suggestionsScrolling", area: area)
    }
}
