// Espalier's menu card in each of its states, light and dark: plain items,
// symbols, subtitles, checks, a choice, sections with headers and
// dividers, destructive and disabled items, a submenu's chevron, the
// highlighted row, and a long menu scrolled to its choice.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Menu snapshots") @MainActor
struct MenuSnapshotTests {
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
        assertSnapshot(card(MenuContent {
            MenuAction("Check Out Branch") {}
            MenuAction("Check Out in New Worktree…") {}
            MenuDivider()
            MenuAction("Copy Branch Name") {}
        }), named: "plain", area: area)
    }

    @Test("symbols and subtitles, under a section header")
    func symbolsAndSubtitles() {
        assertSnapshot(card(MenuContent {
            MenuSection("Fetched 5 minutes ago") {
                MenuAction("Fetch origin", systemImage: "arrow.triangle.2.circlepath", subtitle: "Fetch the latest changes from origin") {}
                MenuAction("Force push origin…", systemImage: "exclamationmark.arrow.triangle.2.circlepath", subtitle: "Overwrite any changes on origin with your local changes") {}
            }
            MenuSection {
                MenuAction("Fetch failed — Show Details…") {}
            }
        }), named: "symbolsSubtitles", area: area)
    }

    @Test("checks: toggles and a choice, set off by a divider")
    func checks() {
        assertSnapshot(card(MenuContent {
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
        assertSnapshot(card(MenuContent {
            MenuPicker(selection: .constant(1)) {
                MenuChoice("Create a merge commit", value: 0, subtitle: "The commits from feature will be added to main via a merge commit.")
                MenuChoice("Squash and merge", value: 1, subtitle: "The 3 commits in feature will be combined into one commit in main.")
                MenuChoice("Rebase", value: 2, subtitle: "The 3 commits in feature will be rebased and added to main.")
            }
        }), named: "choiceSubtitles", area: area)
    }

    @Test("sections with headers, a destructive item, a disabled one, and a submenu")
    func sectionsDestructiveDisabledSubmenu() {
        assertSnapshot(card(MenuContent {
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
        }), named: "sectionsDestructiveDisabledSubmenu", area: area)
    }

    @Test("the highlighted row, a destructive one highlighted, and a disabled one under the highlight")
    func highlighted() {
        let content = MenuContent {
            MenuAction("Rename…", systemImage: "pencil") {}
            MenuAction("Copy Branch Name", systemImage: "doc.on.doc") {}
            MenuAction("View on GitHub", systemImage: "safari") {}.disabled(true)
            MenuDivider()
            MenuAction("Delete…", systemImage: "trash", role: .destructive) {}
        }
        assertSnapshot(card(content, highlighted: "Copy Branch Name"), named: "highlighted", area: area)
        assertSnapshot(card(content, highlighted: "Delete…"), named: "highlightedDestructive", area: area)
        assertSnapshot(card(content, highlighted: "View on GitHub"), named: "highlightedDisabled", area: area)
    }

    @Test("a long menu, scrolled to its choice")
    func scrolled() {
        let names = ["Actionscript", "Ada", "Agda", "Android", "Angular", "AppEngine", "AppceleratorTitanium", "ArchLinuxPackages", "Autotools", "Ballerina", "C", "C++", "CakePHP", "CFWheels", "ChefCookbook", "Clojure", "CMake", "CodeIgniter", "CommonLisp", "Composer", "Concrete5", "Coq", "CraftCMS", "CUDA", "D", "Dart", "Delphi", "DM", "Dotnet", "Drupal"]
        assertSnapshot(card(MenuContent {
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
        assertSnapshot(view, named: "contextTarget", area: area)
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
                Text("Squash and merge")
            } menu: {
                MenuAction("Rebase") {}
            }
            .fixedSize()
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "closedButtons", area: area)
    }
}
