// Ported from desktop/app/test/unit/git/init-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/init")
struct InitTests {
    @Test("creates a repository with a default branch")
    func createsRepositoryWithDefaultBranch() async throws {
        let tempDir = try createTempDirectory()
        try await initGitRepository(tempDir)

        let repo = Repository(path: tempDir)
        let status = try await getStatus(repo)
        #expect(status != nil)
        #expect(status?.exists == true)

        let head = try await Dugite.exec(["symbolic-ref", "--short", "HEAD"], tempDir)
        let defaultBranch = try await getDefaultBranch()
        #expect(String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == defaultBranch)
    }
}
