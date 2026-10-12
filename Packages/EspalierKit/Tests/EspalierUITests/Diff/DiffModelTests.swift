// The diff view on real repositories: the gutter's gestures through
// `DiffLines`, discarding lines through the presenter, hidden whitespace,
// the session's contents (the bottom hunk, expansion, and collapsing), and
// syntax highlighting from the test highlighter; and the line filters that
// say which lines of each version to read.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A repository whose numbered.txt has 30 committed lines, then lines 2 and
/// 15 changed (two hunks, the file going on below the second).
@MainActor
private struct NumberedFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    let repository: Repository

    static func numbered(_ count: Int, replacing: [Int: String] = [:]) -> String {
        (1...count).map { replacing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    static func make() async throws -> NumberedFixture {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try setupEmptyRepository()
        try harness.write("numbered.txt", numbered(30), in: repository)
        _ = try await runGit(["add", "numbered.txt"], repository)
        _ = try await runGit(["commit", "-m", "Number the lines"], repository)
        try harness.write("numbered.txt", numbered(30, replacing: [2: "let two = 2", 15: "let fifteen = 15"]), in: repository)
        let model = try await harness.addAndSelect(repository, to: app)
        await model.refresh(reason: .user)
        return NumberedFixture(harness: harness, app: app, model: model, repository: repository)
    }

    var file: WorkingDirectoryFileChange {
        get throws {
            try #require(model.changes.workingDirectory.files.first { $0.path == "numbered.txt" })
        }
    }

    func selectFile() async throws -> TextDiff {
        model.changes.select(fileIDs: [try file.id])
        await model.changes.diffIdle()
        guard case .loaded(.text(let text)) = model.changes.diff else {
            Issue.record("No text diff: \(model.changes.diff)")
            throw TestSupportError("No text diff")
        }
        return text
    }

    /// The original diff index of a changed line with this content.
    func index(_ type: DiffLineType, _ content: String, in diff: TextDiff) throws -> Int {
        try #require(diff.hunks.flatMap(\.lines).first { $0.type == type && $0.content == content }?.originalLineNumber)
    }
}

@Suite("Diff on repositories", .offline) @MainActor
struct DiffModelTests {
    @Test("the gutter stages lines, drags, blocks, and hunks through the changes model")
    func stagingThroughTheModel() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await NumberedFixture.make()
            let diff = try await fixture.selectFile()
            let changes = fixture.model.changes
            let staging = DiffStaging(changes: changes)
            let state = staging.state(hunks: diff.hunks)
            #expect(state.canSelectLines)
            #expect(!state.hidesWhitespace)

            let controller = DiffTables.controller(DiffTableContent(fileID: try fixture.file.id, diff: diff, staging: state))
            controller.actions = DiffTableActions(staging: staging.actions(hunks: diff.hunks, discard: { _, _ in }))

            // Click the added "let two = 2": excluded.
            let addTwo = try fixture.index(.add, "let two = 2", in: diff)
            let row = try #require(controller.document.rows.indices.first { controller.document.diffLines(ofRow: $0) == [addTwo] })
            let drag = controller.mouseDown(at: point(controller, row: row, x: middle(controller.geometry.before.newNumber!)), clickCount: 1, extendsSelection: false)
            controller.mouseUp(drag: drag)
            #expect(try !fixture.file.selection.isSelected(addTwo))
            #expect(try fixture.file.selection.getSelectionType() == .partial)

            // The view redraws from the model's new selection.
            controller.apply(DiffTableContent(fileID: try fixture.file.id, diff: diff, staging: DiffStaging(changes: changes).state(hunks: diff.hunks)))
            #expect(controller.isIncluded(line: controller.document.rows[row].after.asInt) == false)

            // The block handle includes the partly included block again.
            _ = controller.mouseDown(at: point(controller, row: row, x: middle(controller.geometry.handle!)), clickCount: 1, extendsSelection: false)
            #expect(try fixture.file.selection.getSelectionType() == .all)

            // The second hunk's checkbox excludes it.
            controller.apply(DiffTableContent(fileID: try fixture.file.id, diff: diff, staging: DiffStaging(changes: changes).state(hunks: diff.hunks)))
            let secondHunk = controller.document.hunks[1].row
            _ = controller.mouseDown(at: point(controller, row: secondHunk, x: middle(controller.geometry.hunkCheckbox!)), clickCount: 1, extendsSelection: false)
            let addFifteen = try fixture.index(.add, "let fifteen = 15", in: diff)
            #expect(try !fixture.file.selection.isSelected(addFifteen))
            #expect(try fixture.file.selection.isSelected(addTwo))
            await fixture.model.idle()
        }
    }

    @Test("discarding a line through the presenter changes the file")
    func discardLine() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await NumberedFixture.make()
            fixture.app.preferences.confirmDiscardChanges = false
            let diff = try await fixture.selectFile()
            let changes = fixture.model.changes
            let staging = DiffStaging(changes: changes)
            let presenter = WindowPresenter(app: fixture.app)
            var tasks: [Task<Void, Never>] = []
            let actions = staging.actions(hunks: diff.hunks, discard: { changes, lines in
                tasks.append(Task {
                    await presenter.perform { answers throws(OperationError) in
                        try await changes.discardLines(lines, confirmed: answers.confirmed)
                    }
                })
            })
            let addTwo = try fixture.index(.add, "let two = 2", in: diff)
            #expect(actions.discardTitle(.line(addTwo)) == "Discard Added Line")
            #expect(actions.discardTitle(.block(containing: addTwo)) == "Discard Modified Lines")
            actions.discardLines(.block(containing: addTwo))
            for task in tasks {
                await task.value
            }
            let contents = try String(contentsOf: URL(filePath: POSIXPath.join(fixture.repository.path, "numbered.txt")), encoding: .utf8)
            #expect(contents.contains("line 2\n"))
            #expect(!contents.contains("let two = 2"))
            #expect(contents.contains("let fifteen = 15"))
            #expect(presenter.error == nil)
            await fixture.model.idle()
        }
    }

    @Test("with whitespace hidden, lines can't be staged and the hint shows whitespace again")
    func hiddenWhitespace() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await NumberedFixture.make()
            _ = try await fixture.selectFile()
            let changes = fixture.model.changes
            DiffWhitespace.set(true, context: .changes, repository: fixture.model, preferences: fixture.app.preferences)
            await changes.diffIdle()
            #expect(fixture.app.preferences.hideWhitespaceInChangesDiff)
            guard case .loaded(.text(let diff)) = changes.diff else {
                Issue.record("No diff")
                return
            }
            let staging = DiffStaging(changes: changes)
            let state = staging.state(hunks: diff.hunks)
            #expect(state.hidesWhitespace)
            #expect(!state.canSelectLines)

            let controller = DiffTables.controller(DiffTableContent(fileID: try fixture.file.id, diff: diff, staging: state))
            controller.actions = DiffTableActions(staging: staging.actions(hunks: diff.hunks, discard: { _, _ in }))
            let row = try #require(controller.document.blocks.first?.rows.first)
            _ = controller.mouseDown(at: point(controller, row: row, x: middle(controller.geometry.before.newNumber!)), clickCount: 1, extendsSelection: false)
            #expect(controller.whitespaceHintPoint != nil)
            #expect(try fixture.file.selection.getSelectionType() == .all)

            controller.actions.staging?.showWhitespaceChanges()
            await changes.diffIdle()
            #expect(!fixture.app.preferences.hideWhitespaceInChangesDiff)
            #expect(changes.canSelectLines)
            await fixture.model.idle()
        }
    }

    @Test("the session loads the file's contents: the bottom hunk, expansion, collapse, and syntax tokens")
    func sessionContents() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await NumberedFixture.make()
            let diff = try await fixture.selectFile()
            let info = DiffFileInfo(try fixture.file)
            let session = DiffSession()
            session.highlighter = KeywordTestHighlighter()
            session.fileDidChange(info)
            session.diffDidChange(.text(diff), file: info, repository: fixture.model)
            #expect(session.displayDiff(for: diff, isLarge: false).hunks.count == 2)
            await session.idle()

            // The contents add the bottom hunk (the file goes on past line
            // 18) and enable expansion.
            #expect(session.canExpand(diff, isLarge: false))
            let base = session.displayDiff(for: diff, isLarge: false)
            #expect(base.hunks.count == 3)
            #expect(base.hunks.last?.expansionType == .down)

            // Tokens for the shown lines, from the test highlighter.
            #expect(!session.tokens.isEmpty)
            let generation = session.tokensGeneration
            #expect(generation > 0)
            let added = try #require(base.hunks.flatMap(\.lines).first { $0.content == "let two = 2" })
            let line = DocumentLine(
                text: added.text, type: .add, oldNumber: 0, newNumber: added.newLineNumber ?? 0, diffLineNumber: 0,
                info: LineTextInfo(added.text, skippingFirstScalar: true, tabSize: 4), noTrailingNewLine: false, partner: -1, conflict: nil
            )
            #expect(session.tokens.tokens(for: line)?.first?.style == .keyword)

            // Expanding the short gap above the second hunk merges the two,
            // then the whole file.
            session.expandHunk(1, .up)
            let expanded = session.displayDiff(for: diff, isLarge: false)
            #expect(expanded.hunks.count == 2)
            #expect(expanded.hunks[0].header.newStartLine == 1)
            #expect(session.hasExpandedLines)
            session.expandWholeFile()
            #expect(session.displayDiff(for: diff, isLarge: false).hunks.count == 1)
            await session.idle()
            #expect(session.tokensGeneration > generation)

            session.collapseExpandedLines()
            #expect(!session.hasExpandedLines)
            #expect(session.displayDiff(for: diff, isLarge: false).hunks.count == 3)

            // A new diff of the same file starts over; another file forgets
            // everything.
            session.fileDidChange(DiffFileInfo(path: "other.txt", status: .modified))
            #expect(session.contents == nil)
            #expect(session.tokens.isEmpty)
            await fixture.model.idle()
        }
    }

    @Test("line filters: only additions read the new file; otherwise context reads the old")
    func lineFilters() {
        let added = DiffFixtures.textDiff("""
        diff --git a/a b/a
        index 1111111..2222222 100644
        --- a/a
        +++ b/a
        @@ -1,1 +1,2 @@
         one
        +two
        """)
        #expect(getLineFilters(added.hunks) == LineFilters(oldLineFilter: [], newLineFilter: [0, 1]))
        let mixed = DiffFixtures.swiftChange
        let filters = getLineFilters(mixed.hunks)
        #expect(filters.newLineFilter == [11, 12, 13, 14])
        #expect(filters.oldLineFilter.first == 9)
        #expect(filters.oldLineFilter.contains(11) && filters.oldLineFilter.contains(41))
    }
}
