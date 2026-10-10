// Branch colors (`BranchColors`). A branch's sidebar dot, its ref tag, and
// the line it starts in the graph have one color, whether or not History
// has loaded.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch colors", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchColorTests {
    private let branches = ["main", "feature/hourly-forecast", "fix/locale-units", "release/2.4", "spike/widget-intents", "docs"]

    @Test("the current branch is the accent, the default teal, and the others each have their own entry while entries last")
    func distinctColors() throws {
        let colors = BranchColors(branches: branches, current: "feature/hourly-forecast", defaultBranch: "main", accent: .systemBlue)
        #expect(colors.color(forBranch: "feature/hourly-forecast", accent: .systemBlue) == NSColor.systemBlue)
        #expect(colors.color(forBranch: "main") == TrackPalette.trunk)
        let others = ["fix/locale-units", "release/2.4", "spike/widget-intents", "docs"]
        let tones = others.compactMap { colors.assigned[$0] }
        #expect(tones.count == others.count)
        #expect(Set(tones).count == others.count)
        // Not a local branch: no color of its own.
        #expect(colors.color(forBranch: "origin/main") == nil)
    }

    @Test("a branch's color depends on the branches, not on their order or on what History loaded")
    func stable() {
        let colors = BranchColors(branches: branches, current: "main", defaultBranch: "main", accent: .systemBlue)
        let reordered = BranchColors(branches: branches.reversed(), current: "main", defaultBranch: "main", accent: .systemBlue)
        #expect(colors == reordered)
        // A branch with no rival for its entry keeps the entry its name
        // hashes to.
        let alone = BranchColors(branches: ["docs"], current: nil, defaultBranch: nil, accent: .systemBlue)
        let palette = TrackPalette.palette(accent: .systemBlue)
        #expect(alone.assigned["docs"] == palette[BranchColors.index(of: "docs", count: palette.count)])
    }

    @Test("past the palette's size, branches share entries again")
    func manyBranches() {
        let names = (1...12).map { "branch-\($0)" }
        let colors = BranchColors(branches: names, current: nil, defaultBranch: nil, accent: .systemBlue)
        let palette = TrackPalette.palette(accent: .systemBlue)
        #expect(colors.assigned.count == 12)
        // The first branches (by name) take every entry before any repeats.
        let first = names.sorted().prefix(palette.count).compactMap { colors.assigned[$0] }
        #expect(Set(first).count == palette.count)
        // Every entry is taken, so other lines may use any.
        #expect(colors.otherTones == palette)
    }

    @Test("a remote branch has its local branch's color, else its name's")
    func remoteBranches() {
        let colors = BranchColors(branches: branches, current: "feature/hourly-forecast", defaultBranch: "main", remoteNames: ["origin", "upstream/fork"], accent: .systemBlue)
        #expect(colors.color(forRemoteBranch: "origin/fix/locale-units", accent: .systemBlue) == colors.color(forBranch: "fix/locale-units"))
        #expect(colors.color(forRemoteBranch: "origin/main", accent: .systemBlue) == TrackPalette.trunk)
        #expect(colors.color(forRemoteBranch: "origin/feature/hourly-forecast", accent: .systemBlue) == NSColor.systemBlue)
        #expect(colors.color(forRemoteBranch: "upstream/fork/docs", accent: .systemBlue) == colors.color(forBranch: "docs"))
        // A remote branch with no local one: its name's entry.
        let palette = TrackPalette.palette(accent: .systemBlue)
        let remoteOnly = colors.color(forRemoteBranch: "origin/experiment", accent: .systemBlue)
        #expect(remoteOnly == TrackPalette.color(of: palette[BranchColors.index(of: "experiment", count: palette.count)]))
    }

    @Test("a merged branch's stub: its branch's color while the branch exists, else an entry no branch has")
    func mergedBranches() {
        let colors = BranchColors(branches: ["main", "feature/hourly-forecast", "docs", "release/2.4"], current: "feature/hourly-forecast", defaultBranch: "main", remoteNames: ["origin"], accent: .systemBlue)
        // Local branches, the default branch's teal, and the current one's accent.
        #expect(colors.color(forMergedBranch: "docs", isPullRequest: false, merge: "a1", accent: .systemBlue) == colors.color(forBranch: "docs"))
        #expect(colors.color(forMergedBranch: "main", isPullRequest: false, merge: "a1", accent: .systemBlue) == TrackPalette.trunk)
        #expect(colors.color(forMergedBranch: "feature/hourly-forecast", isPullRequest: false, merge: "a1", accent: .systemBlue) == NSColor.systemBlue)
        // A remote branch is its local branch; a pull request's
        // "owner/branch" is the branch.
        #expect(colors.color(forMergedBranch: "origin/release/2.4", isPullRequest: false, merge: "a1", accent: .systemBlue) == colors.color(forBranch: "release/2.4"))
        #expect(colors.color(forMergedBranch: "jonas/docs", isPullRequest: true, merge: "a1", accent: .systemBlue) == colors.color(forBranch: "docs"))
        // Gone: an entry no branch has, the same for the same name.
        let free = colors.otherTones.map(TrackPalette.color(of:))
        #expect(free.count == TrackPalette.palette(accent: .systemBlue).count - 2)
        let gone = colors.color(forMergedBranch: "jonas/docs", isPullRequest: false, merge: "a1", accent: .systemBlue)
        #expect(free.contains(gone))
        #expect(colors.color(forMergedBranch: "jonas/docs", isPullRequest: false, merge: "b2", accent: .systemBlue) == gone)
        #expect(free.contains(colors.color(forMergedBranch: nil, isPullRequest: false, merge: "a1", accent: .systemBlue)))
    }

    @Test("lines no branch starts take the entries no branch has")
    func otherLines() {
        let colors = BranchColors(branches: ["main", "a", "b"], current: nil, defaultBranch: "main", accent: .systemBlue)
        let used = Set(colors.assigned.values)
        #expect(!colors.otherTones.contains { used.contains($0) })
        let resolved = TrackPalette.Resolved(accent: .systemBlue, currentTrack: nil, branchColors: colors, trackBranches: [2: "a"])
        #expect(resolved.color(forTrack: 2) == colors.color(forBranch: "a"))
        #expect(resolved.otherTracks.allSatisfy { color in !used.contains { TrackPalette.color(of: $0) == color } })
    }

    @Test("a branch's sidebar dot, its tag, and its line in the graph agree, before History loads and after")
    func sidebarAndGraphAgree() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            let repository = fixture.repository
            await fixture.settle()
            @MainActor func dot(_ name: String) throws -> NSColor {
                let branch = try #require(repository.gitState.branches.all.first { $0.name == name })
                let content = BranchRowContent(
                    ref: branch.ref,
                    name: branch.name,
                    isCurrent: name == repository.gitState.tip.branch?.name,
                    isRemote: branch.type == .remote,
                    tipSHA: branch.tip.sha,
                    isDefault: name == repository.gitState.branches.defaultBranch?.name
                )
                return BranchSidebarRow.dotColor(content, in: repository)
            }
            // Before History has loaded anything.
            #expect(fixture.history.graph.isEmpty)
            let before = try ["main", "feature/login", "fix/crash"].map(dot)

            await fixture.show(.history)
            let history = fixture.history
            #expect(!history.graph.isEmpty)
            let after = try ["main", "feature/login", "fix/crash"].map(dot)
            #expect(before == after)

            let presentation = GraphPresentation(repository: repository, place: .history)
            let palette = presentation.palette(for: history)
            for (name, color) in zip(["main", "feature/login", "fix/crash"], after) {
                let branch = try #require(repository.gitState.branches.all.first { $0.name == name })
                let row = try #require(history.row(of: branch.tip.sha))
                let track = history.graph[row].track
                // The line the branch starts.
                #expect(palette.color(forTrack: track) == color, "\(name)'s line")
                // Its tag.
                let kind: RefCapsuleContent.Kind = name == "main" ? .currentBranch : .localBranch
                #expect(palette.color(forRef: RefCapsuleContent(name: name, kind: kind, track: track)) == color, "\(name)'s tag")
            }
            // feature/login is merged: its line starts at the merge, and
            // still takes its color.
            #expect(after[1] != after[0] && after[2] != after[1])
            await fixture.settle()
        }
    }
}
