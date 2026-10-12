// Orchard's references where Classic's don't show what it draws: the
// gallery in each of its other colors, and whole states in Ink and
// Espresso, light and dark: History, Changes with a file's diff, a sheet
// with its fields, choices, and buttons, a menu with its highlighted row,
// and Settings ▸ Git with its switches; Settings ▸ Appearance in Espresso.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Orchard snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct OrchardSnapshotTests {
    /// The colors whole states are drawn in.
    nonisolated static let colors: [DesignThemeColor] = [.ink, .espresso]

    private func look(_ color: DesignThemeColor) -> Look {
        Look(theme: .orchard, color: color)
    }

    @Test("the gallery in each of Orchard's other colors", arguments: [DesignThemeColor.plum, .clay, .teal, .espresso])
    func gallery(_ color: DesignThemeColor) {
        assertSnapshot(ThemeGallery(), named: "gallery", area: "Themes", look: look(color))
    }

    @Test("History: the graph of every local branch, and HEAD's commit's detail", arguments: colors)
    func history(_ color: DesignThemeColor) async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            await fixture.show(.history)
            let look = look(color)
            for appearance in SnapshotAppearance.allCases {
                let image = Look.with(look) {
                    fixture.image(.history, appearance: appearance)
                }
                assertSnapshot(image, named: look.snapshotName("history"), area: "HistoryScreen", appearance: appearance)
            }
            await fixture.settle()
        }
    }

    @Test("Changes: the changed files, one selected with its diff", arguments: colors)
    func changes(_ color: DesignThemeColor) async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let readme = try fixture.file("README.md")
            fixture.repository.changes.select(fileIDs: [readme.id])
            await fixture.settle()
            let look = look(color)
            for appearance in SnapshotAppearance.allCases {
                let image = Look.with(look) {
                    fixture.render(ChangesScreen(repository: fixture.repository), size: CGSize(width: 960, height: 620), appearance: appearance)
                }
                assertSnapshot(image, named: look.snapshotName("place-files"), area: "Changes", appearance: appearance)
            }
            await fixture.settle()
        }
    }

    private enum Choice: Hashable {
        case leave, bring
    }

    @Test("a sheet: capsule fields, a text area, choices, and Cancel and the default button", arguments: colors)
    func sheet(_ color: DesignThemeColor) {
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
        assertSnapshot(view, named: "sheetScaffold", area: "Components", look: look(color))
    }

    @Test("a menu: symbols, a disabled item, a destructive one, and the highlighted row", arguments: colors)
    func menu(_ color: DesignThemeColor) {
        let level = MenuLevel(content: MenuContent {
            MenuAction("Rename…", systemImage: "pencil") {}
            MenuAction("Copy Branch Name", systemImage: "doc.on.doc") {}
            MenuAction("View on GitHub", systemImage: "safari") {}.disabled(true)
            MenuDivider()
            MenuAction("Delete…", systemImage: "trash", role: .destructive) {}
        }, minimumWidth: 0)
        level.highlighted = level.rows.first { $0.item?.title == "Copy Branch Name" }?.id
        assertSnapshot(MenuCard(level: level), named: "highlighted", area: "Menus", look: look(color))
    }

    @Test("Settings ▸ Git: fields, the segmented control, switches on and off, and quiet buttons", arguments: colors)
    func settingsGit(_ color: DesignThemeColor) throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let (context, _) = SettingsFixtures.context(app)
        let settings = GitSettingsModel(app: app, presenter: context.presenter, accounts: [SettingsFixtures.dotComAccount])
        settings.apply(GlobalGitSettings(name: "Joe Bloggs", email: "joe@example.com", defaultBranch: "main"))
        let view = SettingsLayout(selection: .constant(.git)) {
            GitPaneContent(settings: settings, loadsOnAppear: false)
        }
        .frame(width: Metrics.SettingsWindow.width)
        assertSnapshot(view, named: "git-accountEmail", area: "Settings", look: look(color))
    }

    @Test("Settings ▸ Appearance in Espresso: the theme cards, its colors, and the switches")
    func settingsAppearance() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        // A fixed number format, whatever this Mac's region.
        app.preferences.numberFormat = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)
        app.preferences.timeFormat = TimeFormatPattern.colonTwelveHour.rawValue
        app.preferences.designTheme = .orchard
        app.preferences.designThemeColor = .espresso
        let view = SettingsLayout(selection: .constant(.appearance)) {
            AppearanceForm(preferences: app.preferences, openAppearanceSettings: {})
        }
        .frame(width: Metrics.SettingsWindow.width)
        assertSnapshot(view, named: "appearance", area: "Settings", look: Look(preferences: app.preferences))
    }
}
