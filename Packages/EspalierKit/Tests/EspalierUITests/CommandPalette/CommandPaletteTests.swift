// The command palette: how its matcher ranks (prefix, then word starts,
// then the rest; case aside; a query's words in any order, in the title or
// the menu), the section with the best match first, the keyboard's
// highlight, which actions it lists as the window's state changes, and
// that choosing a row runs it: an action, a branch's checkout, and a
// repository switch.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Command palette") @MainActor
struct CommandPaletteRankingTests {
    /// A query, the texts it's matched against, and its matches, best
    /// first.
    struct Ranking: Sendable {
        let query: String
        let texts: [String]
        let ranked: [String]
    }

    /// Sources listing `texts` as branches.
    private static func sources(branches texts: [String]) -> CommandPaletteSources {
        CommandPaletteSources(branches: texts.map { text in
            CommandPaletteItem(id: .branch(ExactString(text)), systemImage: "", title: PaletteSearchText(text), command: .branch(name: text))
        })
    }

    /// The titles `query` lists, in order.
    private static func titles(_ query: String, in sources: CommandPaletteSources) -> [String] {
        sources.sections(for: query).flatMap { $0.rows.map(\.item.title.text) }
    }

    @Test("matches rank the whole text, then a prefix, a word's start, several words' starts, inside a word, and scattered", arguments: [
        NamedCase("a prefix, then a word's start, then scattered", Ranking(
            query: "push",
            texts: ["Publish Branch", "Force Push…", "Pull", "Push"],
            ranked: ["Push", "Force Push…", "Publish Branch"]
        )),
        NamedCase("several words' starts before inside a word", Ranking(
            query: "sb",
            texts: ["Show Stashed Changes", "Usb Devices", "Switch Branch…"],
            ranked: ["Switch Branch…", "Usb Devices"]
        )),
        NamedCase("whatever the case", Ranking(
            query: "MAIN",
            texts: ["feature/MAIN-menu", "Maintenance", "main"],
            ranked: ["main", "Maintenance", "feature/MAIN-menu"]
        )),
        NamedCase("words start after a slash or a dash", Ranking(
            query: "login",
            texts: ["relogin", "feature/login", "login-flow"],
            ranked: ["login-flow", "feature/login", "relogin"]
        )),
        NamedCase("words start at a capital after a lowercase letter", Ranking(
            query: "kit",
            texts: ["skittles", "GitKit", "kitchen"],
            ranked: ["kitchen", "GitKit", "skittles"]
        )),
        NamedCase("of one kind, the match nearer the start", Ranking(
            query: "branch",
            texts: ["Compare to Branch…", "New Branch…", "Branch"],
            ranked: ["Branch", "New Branch…", "Compare to Branch…"]
        )),
        NamedCase("scattered, the match with word starts and runs", Ranking(
            query: "fcr",
            texts: ["fabric-core", "fix/crash"],
            ranked: ["fix/crash", "fabric-core"]
        )),
        NamedCase("nothing for characters out of order", Ranking(
            query: "hsup",
            texts: ["Push", "Force Push…"],
            ranked: []
        )),
    ])
    func ranking(_ testCase: NamedCase<Ranking>) {
        let ranking = testCase.value
        #expect(Self.titles(ranking.query, in: Self.sources(branches: ranking.texts)) == ranking.ranked)
    }

    @Test("a scattered match highlights the best alignment: the word starts and the run after them")
    func scatteredPositions() throws {
        let match = try #require(PaletteQuery("fcr")?.match(PaletteSearchText("fix/crash")))
        #expect(match.positions == [0, 4, 5])
    }

    @Test("a query's words match in any order, each in the title or the action's menu; one word only in the title")
    func words() {
        func action(_ title: String, menu: String, index: Int) -> CommandPaletteItem {
            CommandPaletteItem(
                id: .action(index),
                systemImage: "",
                title: PaletteSearchText(title),
                context: PaletteSearchText(menu),
                command: .action(.about)
            )
        }
        let sources = CommandPaletteSources(actions: [
            action("New Branch…", menu: "Branch", index: 0),
            action("Rename…", menu: "Branch", index: 1),
            action("Remove…", menu: "Repository", index: 2),
            action("Switch Branch…", menu: "Branch", index: 3),
        ])
        #expect(Self.titles("new branch", in: sources) == ["New Branch…"])
        #expect(Self.titles("branch new", in: sources) == ["New Branch…"])
        #expect(Self.titles("branch rename", in: sources) == ["Rename…"])
        #expect(Self.titles("repository re", in: sources) == ["Remove…"])
        #expect(Self.titles("branch", in: sources) == ["New Branch…", "Switch Branch…"])
    }

    @Test("the section with the best match comes first, and with nothing typed the actions do")
    func sectionOrder() {
        var sources = Self.sources(branches: ["main", "feature/login"])
        sources.actions = [CommandPaletteItem(id: .action(0), systemImage: "", title: PaletteSearchText("Show Main Window"), command: .action(.about))]
        sources.recentBranches = [.branch(ExactString("main"))]
        #expect(sources.sections(for: "main").map(\.kind) == [.branches, .actions])
        #expect(sources.sections(for: "show").map(\.kind) == [.actions])
        #expect(sources.sections(for: "").map(\.kind) == [.actions, .branches])
        #expect(sources.sections(for: "  ").first?.rows.count == 1)
    }

    @Test("typing highlights the first match; the arrows move the highlight and stop at the ends")
    func highlight() {
        let model = CommandPaletteModel(sources: Self.sources(branches: ["main", "maintenance", "feature/main-menu"]))
        model.query = "main"
        #expect(model.highlighted == .branch(ExactString("main")))
        model.move(by: -1)
        #expect(model.highlighted == .branch(ExactString("main")))
        model.move(by: 1)
        model.move(by: 1)
        model.move(by: 1)
        #expect(model.highlighted == .branch(ExactString("feature/main-menu")))
        model.query = "nothing like it"
        #expect(model.highlighted == nil)
        #expect(model.highlightedRow == nil)
    }
}

@Suite("Command palette in a window", .offline, .hangGuard(minutes: 5)) @MainActor
struct CommandPaletteWindowTests {
    /// Whether `sources` lists an action of `kind`.
    private func lists(_ kind: ActionKind, _ sources: CommandPaletteSources) -> Bool {
        sources.actions.contains { item in
            if case .action(let action) = item.command {
                return action.kind == kind
            }
            return false
        }
    }

    /// Opens the palette in `fixture`'s window, types `query`, and runs the
    /// highlighted row.
    private func choose(_ query: String, in fixture: OperationsFixture) async throws -> CommandPaletteRow {
        let context = fixture.context
        context.actions.perform(.showCommandPalette)
        await context.actions.idle()
        let model = try #require(context.state.commandPalette)
        model.query = query
        let row = try #require(model.highlightedRow)
        CommandPaletteActions.run(row.item.command, in: context)
        await fixture.settle()
        #expect(context.state.commandPalette == nil)
        return row
    }

    @Test("the palette lists the menu bar's actions that can run now, as the state changes, and not its own")
    func actionsFollowAvailability() async throws {
        let fixture = try await makeOperationsFixture()
        await fixture.loadHistory()
        let context = fixture.context
        context.select(.changes)

        var sources = CommandPaletteSources.make(context)
        #expect(lists(.push, sources))
        #expect(lists(.openSettings, sources))
        #expect(!lists(.showCommandPalette, sources))
        #expect(!lists(.forcePush, sources))
        #expect(!lists(.stashAllChanges, sources))
        #expect(!lists(.copySHA, sources))

        try fixture.harness.write("README.md", "changed\n", in: fixture.local)
        await fixture.refresh()
        context.select(.history)
        fixture.repository.history.select(shas: [try await fixture.sha("HEAD")], contiguous: true)
        sources = CommandPaletteSources.make(context)
        #expect(lists(.stashAllChanges, sources))
        #expect(lists(.copySHA, sources))
    }

    @Test("⌘K opens the palette and closes it while it's open")
    func toggles() async throws {
        let fixture = try await makeOperationsFixture()
        let actions = fixture.context.actions
        actions.perform(.showCommandPalette)
        await actions.idle()
        #expect(fixture.context.state.commandPalette != nil)
        actions.perform(.showCommandPalette)
        await actions.idle()
        #expect(fixture.context.state.commandPalette == nil)
    }

    @Test("choosing an action runs it as its menu item does")
    func runsAction() async throws {
        let fixture = try await makeOperationsFixture()
        fixture.context.select(.changes)
        let row = try await choose("history", in: fixture)
        #expect(row.item.title.text == ActionKind.showHistory.title)
        #expect(fixture.context.state.place == .history)
    }

    @Test("choosing a branch checks it out")
    func checksOutBranch() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let sources = CommandPaletteSources.make(fixture.context)
            #expect(!sources.branches.contains { $0.title.text == "feature" })
            let row = try await choose("other", in: fixture)
            #expect(row.id == .branch(ExactString("refs/heads/other")))
            #expect(try await fixture.currentBranch() == "other")
        }
    }

    @Test("choosing a repository switches the window to it; the current one isn't listed")
    func switchesRepository() async throws {
        let fixture = try await makeOperationsFixture()
        let other = try setupEmptyRepository()
        let added = try await fixture.app.addRepositories([other.path])
        let otherID = try #require(added.added.first)
        await fixture.settle()
        let sources = CommandPaletteSources.make(fixture.context)
        #expect(sources.repositories.map(\.id) == [.repository(otherID)])

        let name = try #require(fixture.app.record(otherID)?.displayName)
        let row = try await choose(name, in: fixture)
        #expect(row.id == .repository(otherID))
        #expect(fixture.app.selection == .repository(otherID))
    }
}
