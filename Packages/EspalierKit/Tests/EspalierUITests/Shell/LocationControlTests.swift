// The location control's segments, and the width a branch's name takes in
// the toolbar.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Location control") @MainActor
struct LocationControlTests {
    @Test("the branch segment: none when hidden, the branch's name, the detached HEAD's symbol, and disabled while an operation runs")
    func segments() {
        let repository = LocationControlState.RepositorySegment.repository(name: "espalier", path: "/p")
        #expect(LocationControlState(repository: repository, branch: .hidden).branchTitle == nil)

        let unborn = LocationControlState(repository: repository, branch: .unborn(ref: "main"))
        #expect(unborn.branchTitle == "main")

        let detached = LocationControlState(repository: repository, branch: .detached(sha: "a1b2c3d4e5f6"))
        #expect(detached.branchSystemImage == "smallcircle.filled.circle")

        let checkingOut = LocationControlState(repository: repository, branch: .checkingOut(target: "dev", description: "Switching to Branch", progress: 0.42))
        #expect(checkingOut.branchTitle == "dev")
        #expect(!checkingOut.isBranchEnabled)

        let rebasing = LocationControlState(repository: repository, branch: .rebasing(target: "main"))
        #expect(!rebasing.isBranchEnabled)

        // An operation in progress: the branch, disabled.
        let blocked = LocationControlState(repository: repository, branch: .branch(name: "main"), branchBlockedReason: "Finish or abort the merge first.")
        #expect(blocked.branchTitle == "main")
        #expect(!blocked.isBranchEnabled)
        #expect(LocationControlState(repository: repository, branch: .branch(name: "main")).isBranchEnabled)
    }

    @Test("an operation in progress disables the branch segment; a rebase, interrupted or not, says Rebasing", .offline, .hangGuard(minutes: 5))
    func operationsInProgress() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let operations = fixture.repository.operations
            #expect(LocationControlState.make(fixture.app).branch == .branch(name: "feature"))
            #expect(LocationControlState.make(fixture.app).isBranchEnabled)

            // A merge with its conflicts staged.
            #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
            try fixture.harness.write("README.md", "resolved\n", in: fixture.local)
            try await fixture.git(["add", "README.md"])
            await fixture.refresh()
            let merging = LocationControlState.make(fixture.app)
            #expect(merging.branch == .branch(name: "feature"))
            #expect(!merging.isBranchEnabled)
            try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
            await fixture.settle()
            #expect(LocationControlState.make(fixture.app).isBranchEnabled)

            // A rebase stopped on conflicts.
            #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)
            await fixture.settle()
            #expect(LocationControlState.make(fixture.app) == LocationControlState(
                repository: .repository(name: fixture.repository.record.displayName, path: fixture.repository.record.path),
                branch: .rebasing(target: "feature")
            ))
            try await operations.abortOperation()
            await fixture.settle()

            // A rebase interrupted between commits (onto where it starts).
            try await interruptRebase(of: "feature", onto: "other", in: fixture.local)
            await fixture.refresh()
            #expect(operations.current?.phase == .interrupted)
            #expect(LocationControlState.make(fixture.app).branch == .rebasing(target: "feature"))
            #expect(!LocationControlState.make(fixture.app).isBranchEnabled)
            try await operations.abortOperation()
            await fixture.settle()
            #expect(LocationControlState.make(fixture.app).branch == .branch(name: "feature"))
        }
    }

    @Test("the state comes from the app's selection", .offline)
    func derived() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            #expect(LocationControlState.make(app) == LocationControlState(repository: .noRepositories, branch: .hidden))

            let repository = try setupEmptyRepository("main")
            let model = try await harness.addAndSelect(repository, to: app)
            #expect(LocationControlState.make(app).repository == .repository(name: model.record.displayName, path: model.record.path))
            #expect(LocationControlState.make(app).branch == .unborn(ref: "main"))

            app.select(nil)
            #expect(LocationControlState.make(app) == LocationControlState(repository: .selectRepository, branch: .hidden))

            // A clone is named for its URL, as the sidebar names it.
            let clone = CloneTask(url: "https://github.com/joe/swift.git", path: "/Users/joe/Developer/swift-copy")
            app.clones.clones.append(clone)
            app.select(.clone(clone.id))
            #expect(LocationControlState.make(app) == LocationControlState(repository: .cloning(name: "swift"), branch: .hidden))
            app.select(nil)
            app.clones.clones.removeAll()
            await app.idle()
        }
    }

    @Test("in the toolbar, a branch's name shows whole at any width proposed", arguments: [
        NamedCase("main", "main"),
        NamedCase("a hyphenated name", "ui-audit"),
        NamedCase("a path", "fix/ui-audit-2"),
    ])
    func toolbarWidth(_ testCase: NamedCase<String>) {
        let state = LocationControlState(repository: .repository(name: "Espalier", path: "/p"), branch: .branch(name: testCase.value))
        let ideal = Self.controlWidth(state, in: 600, inToolbarItem: false)
        // The toolbar proposes the item's measured width, rounded up; a
        // width just over what the control needs truncated "ui-audit" to
        // "ui-…".
        for proposed in [ideal.rounded(.up), ideal - 20] {
            #expect(Self.controlWidth(state, in: proposed, inToolbarItem: true) == ideal, "\(proposed) points proposed")
        }
    }

    /// The width the control takes in a window `width` wide, alone or in
    /// its toolbar item's layout.
    private static func controlWidth(_ state: LocationControlState, in width: CGFloat, inToolbarItem: Bool) -> CGFloat {
        var laidOut: CGFloat = 0
        let control = LocationControlView(state)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { laidOut = $0 }
        let view = Group {
            if inToolbarItem {
                WholePointWidth { control }
            } else {
                control
            }
        }
        .frame(width: width, alignment: .leading)
        let (window, _) = hostInWindow(view, size: CGSize(width: width, height: Metrics.ControlHeight.toolbar))
        window.contentView = nil
        return laidOut
    }

}
