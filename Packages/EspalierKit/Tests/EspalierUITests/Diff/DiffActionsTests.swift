// The View menu's diff options and the Debug menu's Diff Open Benchmark:
// Hide Whitespace Changes follows the place showing and reloads its diff;
// stashes have no setting.

import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff actions", .offline) @MainActor
struct DiffActionsTests {
    @Test("Hide Whitespace Changes follows the place; the other options toggle their settings")
    func viewMenu() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            let context = WindowContext(app: app)
            let preferences = app.preferences

            context.select(.changes)
            #expect(context.actions.canPerform(.toggleHideWhitespace))
            #expect(!context.actions.isChecked(.toggleHideWhitespace))
            await context.actions.performAndWait(.toggleHideWhitespace)
            #expect(preferences.hideWhitespaceInChangesDiff)
            #expect(!preferences.hideWhitespaceInHistoryDiff)
            #expect(context.actions.isChecked(.toggleHideWhitespace))

            context.select(.history)
            #expect(!context.actions.isChecked(.toggleHideWhitespace))
            await context.actions.performAndWait(.toggleHideWhitespace)
            #expect(preferences.hideWhitespaceInHistoryDiff)

            context.select(.stash(branch: "main"))
            #expect(!context.actions.canPerform(.toggleHideWhitespace))

            let split = preferences.showSideBySideDiff
            await context.actions.performAndWait(.toggleSplitDiff)
            #expect(preferences.showSideBySideDiff == !split)
            let wraps = preferences.wrapDiffLines
            await context.actions.performAndWait(.toggleWrapLines)
            #expect(preferences.wrapDiffLines == !wraps)
            await context.actions.performAndWait(.setImageDiffType(.onionSkin))
            #expect(preferences.imageDiffType == .onionSkin)
            #expect(context.actions.isChecked(.setImageDiffType(.onionSkin)))

            #expect(Benchmarks.runners[.diffOpen] != nil)
            await repository.idle()
        }
    }
}
