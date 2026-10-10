// These drive `HistoryModel`'s selection against real git: contiguous
// ranges and their `shasInDiff`, unreachable commits, stale results, the
// whitespace setting, and the selection across reloads.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("History selection", .offline) @MainActor
struct CommitSelectionTests {
    /// A linear `main`: A (a.txt), B (b.txt), C (a.txt again), D (c.txt).
    private func makeLinearRepository() async throws -> (HistoryFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            shas["B"] = try await commitWithGit(repository, "b.txt", "b\n", message: "B")
            shas["C"] = try await commitWithGit(repository, "a.txt", "a\nmore\n", message: "C")
            shas["D"] = try await commitWithGit(repository, "c.txt", "c\n", message: "D")
        }
        await fixture.activate()
        return (fixture, shas)
    }

    @Test("selects HEAD's commit when the history loads, with its files and the first file's diff")
    func selectsHEAD() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        let selection = fixture.history.selection

        #expect(selection.shas == [shas["D"]!])
        #expect(selection.shasInDiff == [shas["D"]!])
        #expect(selection.isContiguous)
        #expect(selection.changeset.value?.files.map(\.path) == ["c.txt"])
        #expect(selection.changeset.value?.linesAdded == 1)
        #expect(selection.file?.path == "c.txt")
        guard case .text(let diff)? = selection.diff.value else {
            Issue.record("Expected a text diff, got \(String(describing: selection.diff))")
            return
        }
        #expect(diff.text.contains("+c"))
    }

    @Test("a contiguous range shows every commit in it")
    func contiguousRange() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        fixture.history.select(shas: [shas["B"]!, shas["D"]!, shas["C"]!], contiguous: true)
        await fixture.history.idle()
        let selection = fixture.history.selection

        // Walked from the newest commit through parents in the selection.
        #expect(selection.shasInDiff == [shas["D"]!, shas["C"]!, shas["B"]!])
        #expect(selection.unreachableSHAs.isEmpty)
        #expect(selection.hasDiff)
        // `B^..D`: a.txt, b.txt, c.txt.
        #expect(selection.changeset.value?.files.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(selection.file?.path == "a.txt")
        #expect(selection.diff.value != nil)
    }

    @Test("a range from the first commit diffs from the empty tree")
    func rangeFromRootCommit() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        fixture.history.select(shas: [shas["A"]!, shas["B"]!], contiguous: true)
        await fixture.history.idle()

        #expect(fixture.history.selection.changeset.value?.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(fixture.history.selection.diff.value != nil)
    }

    @Test("a selection that isn't contiguous has no changes to show")
    func notContiguous() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        fixture.history.select(shas: [shas["D"]!, shas["B"]!], contiguous: false)
        await fixture.history.idle()
        let selection = fixture.history.selection

        #expect(selection.shas == [shas["D"]!, shas["B"]!])
        #expect(selection.shasInDiff == [shas["B"]!, shas["D"]!])
        #expect(selection.isContiguous == false)
        #expect(selection.hasDiff == false)
        #expect(selection.changeset == .idle)
        #expect(selection.file == nil)
        #expect(selection.diff == .idle)
    }

    @Test("commits of a merged branch interleaved in the range are unreachable")
    func unreachableCommits() async throws {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            try await runGit(["checkout", "-q", "-b", "feature"], repository)
            shas["F1"] = try await commitWithGit(repository, "f.txt", "f1\n", message: "F1")
            shas["F2"] = try await commitWithGit(repository, "f.txt", "f2\n", message: "F2")
            try await runGit(["checkout", "-q", "main"], repository)
            shas["M1"] = try await commitWithGit(repository, "m.txt", "m\n", message: "M1")
            try await runGit(["merge", "-q", "--no-ff", "-m", "Merge feature", "feature"], repository)
            shas["Merge"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
        await fixture.activate()
        let history = fixture.history
        // Pick two adjacent rows where the upper one isn't a descendant of
        // the lower one: one of the feature's commits and main's M1.
        let rows = history.commitSHAs
        let pairs = zip(rows, rows.dropFirst()).map { [$0, $1] }
        let pair = try #require(pairs.first { Set($0) == Set([shas["F1"]!, shas["M1"]!]) || Set($0) == Set([shas["F2"]!, shas["M1"]!]) },
                                "\(rows)")
        history.select(shas: pair, contiguous: true)
        await history.idle()
        let selection = history.selection

        // The newer row's commit can't reach the older one's.
        #expect(selection.shasInDiff == [pair[0]])
        #expect(selection.unreachableSHAs == [pair[1]])

        // From the merge down, everything is reachable.
        history.select(shas: Array(rows.prefix(4)), contiguous: true)
        await history.idle()
        #expect(Set(history.selection.shasInDiff) == Set(rows.prefix(4)))
        #expect(history.selection.unreachableSHAs.isEmpty)
    }

    @Test("selecting the same commits again loads nothing")
    func sameSelection() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        let file = try #require(fixture.history.selection.changeset.value?.files.first)
        fixture.history.selectFile(nil)
        #expect(fixture.history.selection.file == nil)

        fixture.history.select(shas: [shas["D"]!], contiguous: true)
        // A no-op: the selection, including the file, stays.
        #expect(fixture.history.selection.changeset.value?.files.first == file)
        #expect(fixture.history.selection.file == nil)
        #expect(fixture.history.selection.diff == .idle)
    }

    @Test("a newer selection's changes always win over an older one's")
    func staleChangesetDiscarded() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        // Each load is replaced at once, so B's files never land on C.
        for _ in 0..<5 {
            fixture.history.select(shas: [shas["B"]!], contiguous: true)
            fixture.history.select(shas: [shas["C"]!], contiguous: true)
        }
        #expect(fixture.history.selection.changeset.isLoading)
        await fixture.history.idle()

        let selection = fixture.history.selection
        #expect(selection.shas == [shas["C"]!])
        #expect(selection.changeset.value?.files.map(\.path) == ["a.txt"])
        #expect(selection.file?.path == "a.txt")
        #expect(selection.file?.commitish == shas["C"])
        guard case .text(let diff)? = selection.diff.value else {
            Issue.record("Expected C's text diff")
            return
        }
        #expect(diff.text.contains("+more"))

        // A file's diff from an older file selection never lands either.
        let files = try #require(selection.changeset.value?.files)
        fixture.history.select(shas: [shas["B"]!, shas["C"]!], contiguous: true)
        await fixture.history.idle()
        let rangeFiles = try #require(fixture.history.selection.changeset.value?.files)
        fixture.history.selectFile(rangeFiles[1])
        fixture.history.selectFile(rangeFiles[0])
        await fixture.history.idle()
        #expect(fixture.history.selection.file == rangeFiles[0])
        guard case .text(let rangeDiff)? = fixture.history.selection.diff.value else {
            Issue.record("Expected a text diff")
            return
        }
        #expect(rangeDiff.text.contains("more"))
        #expect(files.count == 1)
    }

    @Test("hiding whitespace reloads the selected file's diff and is remembered")
    func hideWhitespace() async throws {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "one\ntwo\n", message: "A")
            shas["B"] = try await commitWithGit(repository, "a.txt", "one  \ntwo\n", message: "Whitespace")
        }
        await fixture.activate()
        let preferences = fixture.app.preferences
        #expect(preferences.hideWhitespaceInHistoryDiff == false)
        guard case .text(let shown)? = fixture.history.selection.diff.value else {
            Issue.record("Expected a text diff")
            return
        }
        #expect(!shown.hunks.isEmpty)

        fixture.history.setHideWhitespaceInDiff(true)
        #expect(preferences.hideWhitespaceInHistoryDiff)
        await fixture.history.idle()
        guard case .text(let hidden)? = fixture.history.selection.diff.value else {
            Issue.record("Expected a text diff")
            return
        }
        #expect(hidden.hunks.isEmpty)

        fixture.history.setHideWhitespaceInDiff(false)
        await fixture.history.idle()
        #expect(preferences.hideWhitespaceInHistoryDiff == false)
        #expect(fixture.history.selection.diff.value == .text(shown))
    }

    @Test("a reload keeps the selection while its commit is listed, else selects HEAD's")
    func selectionAcrossReloads() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        fixture.history.select(shas: [shas["B"]!], contiguous: true)
        await fixture.history.idle()

        let e = try await fixture.commit("e.txt", "e\n", message: "E")
        await fixture.refresh()
        #expect(fixture.history.commitSHAs.first == e)
        #expect(fixture.history.selection.shas == [shas["B"]!])

        // Amending E removes it: the selection moves to the new HEAD.
        fixture.history.select(shas: [e], contiguous: true)
        try await fixture.git(["commit", "-q", "--amend", "-m", "E amended"])
        await fixture.refresh()
        let amended = try await fixture.sha("HEAD")
        #expect(fixture.history.commitSHAs.first == amended)
        #expect(fixture.history.selection.shas == [amended])
        #expect(fixture.history.selection.changeset.value?.files.map(\.path) == ["e.txt"])
    }

    @Test("the uncommitted-work row can be selected, and stays selected across reloads")
    func workingCopySelection() async throws {
        let (fixture, shas) = try await makeLinearRepository()
        fixture.history.selectWorkingCopy()
        #expect(fixture.history.isWorkingCopySelected)
        #expect(fixture.history.selection == CommitSelection())

        _ = try await fixture.commit("e.txt", "e\n", message: "E")
        await fixture.refresh()
        #expect(fixture.history.isWorkingCopySelected)
        #expect(fixture.history.selection == CommitSelection())

        fixture.history.select(shas: [shas["A"]!], contiguous: true)
        #expect(fixture.history.isWorkingCopySelected == false)
    }

    @Test("a commit selected before the history lists it (a cherry-pick's) stays selected")
    func selectingAnUnlistedCommit() async throws {
        let (fixture, _) = try await makeLinearRepository()
        // As a cherry-pick does right after creating the commit.
        let e = try await fixture.commit("e.txt", "e\n", message: "E")
        fixture.history.select(shas: [e], contiguous: true)
        await fixture.history.idle()
        #expect(fixture.history.selection.changeset.value?.files.map(\.path) == ["e.txt"])

        await fixture.refresh()
        #expect(fixture.history.commitSHAs.first == e)
        #expect(fixture.history.selection.shas == [e])
    }

    @Test("parent and child rows, for going along lines from the keyboard")
    func parentAndChildRows() async throws {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            try await runGit(["checkout", "-q", "-b", "feature"], repository)
            shas["F"] = try await commitWithGit(repository, "f.txt", "f\n", message: "F")
            try await runGit(["checkout", "-q", "main"], repository)
            shas["M"] = try await commitWithGit(repository, "m.txt", "m\n", message: "M")
            try await runGit(["merge", "-q", "--no-ff", "-m", "Merge", "feature"], repository)
            shas["Merge"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
        await fixture.activate()
        let history = fixture.history
        func row(_ name: String) -> Int {
            history.row(of: shas[name]!) ?? -1
        }

        // The uncommitted-work node's parent is HEAD's commit, and back.
        #expect(history.parentRow(ofRow: 0) == row("Merge"))
        #expect(history.parentRow(ofRow: 0, parentIndex: 1) == nil)
        #expect(history.childRows(ofRow: row("Merge")) == [0])

        #expect(history.parentRow(ofRow: row("Merge")) == row("M"))
        #expect(history.parentRow(ofRow: row("Merge"), parentIndex: 1) == row("F"))
        #expect(history.parentRow(ofRow: row("Merge"), parentIndex: 2) == nil)
        #expect(history.childRows(ofRow: row("M")) == [row("Merge")])
        #expect(history.childRows(ofRow: row("F")) == [row("Merge")])
        // A's first-parent children (M and F), top to bottom.
        #expect(history.childRows(ofRow: row("A")) == [row("M"), row("F")].sorted())
        #expect(history.parentRow(ofRow: row("A")) == nil)
    }

    @Test("ordering and the reachable walk, as desktop's helpers")
    func helpers() {
        let list = ["d", "c", "b", "a"]
        let index = { (sha: String) in list.firstIndex(of: sha) }
        #expect(orderShasByHistory(["b", "d", "c"], index: index) == ["b", "c", "d"])
        #expect(orderShasByHistory(["d", "a"], index: index) == ["a", "d"])
        // Unlisted commits keep their order after the listed ones.
        #expect(orderShasByHistory(["x", "d", "y", "a"], index: index) == ["a", "d", "x", "y"])

        let parents = ["d": ["c"], "c": ["b", "x"], "b": ["a"], "a": []]
        #expect(getShasInDiff(["a", "b", "c", "d"], isContiguous: true) { parents[$0] } == ["d", "c", "b", "a"])
        #expect(getShasInDiff(["b", "d"], isContiguous: true) { parents[$0] } == ["d"])
        #expect(getShasInDiff(["b", "d"], isContiguous: false) { parents[$0] } == ["b", "d"])
        #expect(getShasInDiff(["d"], isContiguous: true) { parents[$0] } == ["d"])
    }
}
