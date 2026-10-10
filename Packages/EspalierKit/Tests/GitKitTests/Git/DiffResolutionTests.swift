// Ported from desktop/app/test/unit/git/diff-resolution-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/diff/getResolutionDiff")
struct DiffResolutionTests {
    @Test("diffs resolved content against the on-disk file")
    func resolvedContent() async throws {
        let repo = try setupEmptyRepository()

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "original\n")],
            commitMessage: "init"
        ))

        let resolved = "modified\n"
        let result = try await getResolutionDiff(repo, "file.txt", .content(resolved))

        #expect(result.diff.kind == .text)
        guard case .text(let textDiff) = result.diff else {
            return
        }
        #expect(textDiff.text.contains("-original"))
        #expect(textDiff.text.contains("+modified"))

        // The contents the diff was made from.
        #expect(result.oldContents == "original\n")
        #expect(result.newContents == resolved)
    }
}
