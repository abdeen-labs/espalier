// The band above a conflicted file's diff (whose conflicts aren't drawn as
// blocks) picks a side for the whole file, and clears it with Undo, as the
// file's menu in the Changes list does.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Conflict band", .offline, .hangGuard(minutes: 5)) @MainActor
struct ConflictBandTests {
    @Test("a side's button resolves the file as the menu's item does, and Undo clears it", arguments: [
        NamedCase("ours", ManualConflictResolution.ours),
        NamedCase("theirs", ManualConflictResolution.theirs),
    ])
    func side(_ side: NamedCase<ManualConflictResolution>) async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesWindowFixture.make(try await setupConflictedRepo())
            let repository = fixture.repository
            let operations = repository.operations
            @MainActor func row() throws -> ConflictFileRowContent {
                try #require(FileList.conflictRows(repository, numberFormat: fixture.app.preferences.numberFormat)[ExactString("foo")])
            }
            @MainActor func button(_ kind: ConflictFileAction.Kind) throws -> ConflictFileAction {
                let row = try row()
                let actions = ConflictFileRowActions.make(for: row, repository: repository, context: fixture.context)
                return try #require(row.bandActions(actions, includesSides: true).first { $0.kind == kind })
            }
            #expect(operations.unresolvedFiles.map(\.path) == ["foo"])

            try button(side.value == .ours ? .ours : .theirs).perform()
            let chosen = operations.conflictState
            #expect(chosen?.manualResolutions["foo"] == side.value)
            #expect(operations.unresolvedFiles.isEmpty)
            #expect(try row().state == .resolved(isUndoable: true))

            try button(.undo).perform()
            #expect(operations.conflictState?.manualResolutions["foo"] == nil)
            #expect(operations.unresolvedFiles.map(\.path) == ["foo"])

            // The file's menu, for the same side.
            ChangesController(context: fixture.context, repository: repository).run(.resolve(side.value), on: [try fixture.file("foo").id])
            #expect(operations.conflictState == chosen)
        }
    }
}
