// Ported from desktop/app/test/unit/git-store-test.ts
// The `loadCommitBatch` case: the history model loads its first page of
// 100 commits, here in the Current Branch scope. HistoryPagingTests pages
// the default scope.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport

@Suite("GitStore", .offline) @MainActor
struct GitStoreLoadCommitBatchTests {
    @Suite("loadCommitBatch", .offline) @MainActor
    struct LoadCommitBatch {
        @Test("includes HEAD when loading commits")
        func includesHEAD() async throws {
            let fixture = try await makeHistoryFixture(fixture: "repository-with-105-commits")
            fixture.history.setScope(.currentBranch)
            await fixture.activate()

            let commits = fixture.history.commitSHAs
            #expect(commits.count == 100)
            #expect(commits[0] == "708a46eac512c7b2486da2247f116d11a100b611")
        }
    }
}
