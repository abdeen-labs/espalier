// Add Worktree's Local Path: a folder that isn't a full path is the field's
// problem before Create Worktree, and a leading `~` is the home folder.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Add Worktree's folder", .offline) @MainActor
struct AddWorktreePathTests {
    @Test("a folder that isn't a full path is the field's problem; a leading ~ is the home folder")
    func folder() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(try await setupTwoCommitRepo(), to: app)
        func content(_ directory: String) -> AddWorktreeContent {
            AddWorktreeContent.make(
                name: "topic",
                directory: directory,
                branchName: "",
                repository: repository,
                isCreating: false,
                itemExists: { _ in AddWorktreeContent.ItemAtPath.none }
            )
        }

        let relative = content("trees")
        #expect(relative.pathProblem != nil)
        #expect(!relative.canCreate)

        let home = content("~/trees")
        #expect(home.path == POSIXPath.join(NSHomeDirectory(), "trees", "topic"))
        #expect(home.pathProblem == nil)
        #expect(home.canCreate)
        await app.idle()
    }
}
