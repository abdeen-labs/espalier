// Pop's own references, where it draws what Classic's don't show: History's
// rows (solid ref tags, the haloed current commit, the selection's bar,
// saturated monograms), Changes with a diff (the accent's marks, solid file
// badges), and Settings ▸ Appearance with Pop chosen (the sidebar's bold
// selection), in each of Pop's colors; and a menu and a sheet in
// Tangerine. Each is a Classic reference's state, under its name with
// Pop's suffix. The rest of the app is checked in Pop with a review run
// (SnapshotAssert.swift).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Pop snapshots", .offline) @MainActor
struct PopThemeSnapshotTests {
    nonisolated static let colors: [DesignThemeColor] = [.tangerine, .electric, .magenta]

    @Test("History's rows: the working copy, HEAD with refs, a merge, unpushed commits, and selection", arguments: colors)
    func historyRows(_ color: DesignThemeColor) {
        let look = Look(theme: .pop, color: color)
        for appearance in SnapshotAppearance.allCases {
            let image = Look.with(look) {
                let history = SyntheticHistory(graphCommits("""
                    M m3 f2
                    f2 f1
                    f1 m2
                    m3 m2
                    m2 m1
                    m1 A
                    A
                    """), options: CommitGraphOptions(trunkTip: "M", includesUncommittedWork: true, headSHA: "M"))
                history.publishFirstPage(7)
                history.localSHAs = ["M", "f2"]
                history.refsBySHA = [
                    "M": [
                        HistoryRef(kind: .localBranch, fullName: "refs/heads/main", name: "main", upstream: "refs/remotes/origin/main"),
                        HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/main", name: "origin/main"),
                    ],
                    "f2": [HistoryRef(kind: .localBranch, fullName: "refs/heads/feature/login", name: "feature/login")],
                    "m2": [
                        HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/release", name: "origin/release"),
                        HistoryRef(kind: .tag, fullName: "refs/tags/v1.2", name: "v1.2"),
                        HistoryRef(kind: .tag, fullName: "refs/tags/v1.1", name: "v1.1"),
                        HistoryRef(kind: .tag, fullName: "refs/tags/v1.0", name: "v1.0"),
                    ],
                ]
                var presentation = GraphPresentation()
                presentation.headSHA = "M"
                presentation.currentBranch = "main"
                presentation.remoteNames = ["origin"]
                presentation.workingCopy = WorkingCopySummary(changedFiles: 3)
                let harness = GraphTableHarness(history, presentation: presentation, size: CGSize(width: 640, height: 200), appearance: appearance)
                harness.selection = GraphSelection(shas: ["f1"])
                harness.update()
                return harness.image()
            }
            assertSnapshot(image, named: look.snapshotName("rows"), area: "HistoryTable", appearance: appearance)
        }
    }

    @Test("Changes: files with the diff", .hangGuard(minutes: 5), arguments: colors)
    func changes(_ color: DesignThemeColor) async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            fixture.repository.changes.select(fileIDs: [try fixture.file("README.md").id])
            await fixture.settle()
            let look = Look(theme: .pop, color: color)
            for appearance in SnapshotAppearance.allCases {
                let image = Look.with(look) {
                    fixture.render(ChangesScreen(repository: fixture.repository), size: CGSize(width: 960, height: 620), appearance: appearance)
                }
                assertSnapshot(image, named: look.snapshotName("place-files"), area: "Changes", appearance: appearance)
            }
        }
    }

    @Test("Settings ▸ Appearance with Pop chosen", arguments: colors)
    func appearance(_ color: DesignThemeColor) throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        // A fixed number format, whatever this Mac's region.
        app.preferences.numberFormat = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)
        app.preferences.timeFormat = TimeFormatPattern.colonTwelveHour.rawValue
        app.preferences.designTheme = .pop
        app.preferences.designThemeColor = color
        let view = SettingsLayout(selection: .constant(.appearance)) {
            AppearanceForm(preferences: app.preferences, openAppearanceSettings: {})
        }
        .frame(width: Metrics.SettingsWindow.width)
        assertSnapshot(view, named: "appearance", area: "Settings", look: Look(theme: .pop, color: color))
    }

    @Test("a menu: sections with headers, a destructive item, a disabled one, and a submenu")
    func menu() {
        let level = MenuLevel(content: MenuContent {
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
        }, minimumWidth: 0)
        assertSnapshot(MenuCard(level: level), named: "sectionsDestructiveDisabledSubmenu", area: "Menus", look: Look(theme: .pop))
    }

    private enum Choice: Hashable {
        case leave, bring
    }

    @Test("the sheet scaffold: a capsule field, a text area, choices, and Cancel and the default button")
    func sheetScaffold() {
        let view = SheetScaffold("Create a Branch", message: "Branches keep your work apart until it's ready.") {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Name")
                TextField("Name", text: .constant("feature/hourly-forecast"))
                    .textFieldStyle(.capsule)
                TextField("Filter", text: .constant(""), prompt: Text("Filter"))
                    .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
                TextField("Disabled", text: .constant("Can't change"))
                    .textFieldStyle(.capsule)
                    .disabled(true)
            }
            Text("Requests hourly data with the daily forecast.")
                .font(Typography.row)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .textAreaSurface()
            ChoiceList("Base", selection: .constant(Choice.leave), choices: [
                ChoiceListItem("Leave my changes on main", description: "Your in-progress work will be stashed on this branch.", value: .leave),
                ChoiceListItem("Bring my changes to feature/login", description: "Your in-progress work will follow you.", value: .bring),
            ])
        } buttons: {
            SheetButtons("Create Branch", isWorking: true, cancel: {}, confirm: {})
        }
        assertSnapshot(view, named: "sheetScaffold", area: "Components", look: Look(theme: .pop))
    }
}
