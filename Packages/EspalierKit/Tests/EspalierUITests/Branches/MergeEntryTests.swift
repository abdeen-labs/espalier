// Every way to merge, squash and merge, or rebase the current branch with
// another ends on that branch's Ahead with the method chosen, and its call
// to action runs that method: the Branch menu's commands (and their
// shortcuts) open the branch popover as the method's picker, whose pick
// shows the branch's place; a branch row's menu names the branch; a place
// already on Ahead takes the method at once.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Merge entry points", .offline, .hangGuard(minutes: 5)) @MainActor
struct MergeEntryTests {
    /// `main`, checked out, with M (not pushed), and `feature` from main's
    /// first commit with F1 and F2: they've diverged, so each method leaves
    /// its own history.
    private func divergedFixture() async throws -> OperationsFixture {
        let fixture = try await makeOperationsFixture { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "F1.txt", "F1\n", message: "F1")
            try await commitFile(local, "F2.txt", "F2\n", message: "F2")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "M.txt", "M\n", message: "M")
        }
        await fixture.loadHistory()
        return fixture
    }

    @Test("the Branch menu's commands open the branch popover as the method's picker; picking a branch shows its Ahead with the method chosen, which starting runs", arguments: [
        NamedCase("Merge into Current Branch…", (ActionID.mergeIntoCurrentBranch(branch: nil), CompareMethod.merge)),
        NamedCase("Squash and Merge into Current Branch…", (ActionID.squashAndMergeIntoCurrentBranch(branch: nil), CompareMethod.squashMerge)),
        NamedCase("Rebase Current Branch…", (ActionID.rebaseCurrentBranch(onto: nil), CompareMethod.rebase)),
    ])
    func menuCommands(_ entry: NamedCase<(ActionID, CompareMethod)>) async throws {
        try await withIsolatedGitConfig { _ in
            let (action, method) = entry.value
            let fixture = try await divergedFixture()
            let context = fixture.context
            let m = try await fixture.sha("main"), f2 = try await fixture.sha("feature")

            await context.actions.performAndWait(action)
            #expect(context.state.isBranchPopoverPresented)
            #expect(context.state.branchPopoverMethod == method)

            let feature = try fixture.branch("feature")
            BranchPopover.pick(feature, for: method, in: context)
            await fixture.settle()
            #expect(!context.state.isBranchPopoverPresented)
            #expect(context.state.branchPopoverMethod == nil)

            try await enterAhead(of: feature, expecting: method, fixture)
            await start(feature, fixture)
            try await expectRan(method, fixture, m: m, f2: f2)
        }
    }

    @Test("a branch row's menu, naming the branch, shows its Ahead with the method chosen, which starting runs", arguments: [
        NamedCase("Merge into main…", (ActionID.mergeIntoCurrentBranch(branch: "feature"), CompareMethod.merge)),
        NamedCase("squash and merge", (ActionID.squashAndMergeIntoCurrentBranch(branch: "feature"), CompareMethod.squashMerge)),
        NamedCase("Rebase main onto feature…", (ActionID.rebaseCurrentBranch(onto: "feature"), CompareMethod.rebase)),
    ])
    func namedBranch(_ entry: NamedCase<(ActionID, CompareMethod)>) async throws {
        try await withIsolatedGitConfig { _ in
            let (action, method) = entry.value
            let fixture = try await divergedFixture()
            let m = try await fixture.sha("main"), f2 = try await fixture.sha("feature")

            await fixture.context.actions.performAndWait(action)
            #expect(!fixture.context.state.isBranchPopoverPresented)
            let feature = try fixture.branch("feature")
            try await enterAhead(of: feature, expecting: method, fixture)
            await start(feature, fixture)
            try await expectRan(method, fixture, m: m, f2: f2)
        }
    }

    @Test("on the branch's Ahead already, another method's entry point chooses it at once")
    func alreadyOnAhead() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await divergedFixture()
            let m = try await fixture.sha("main"), f2 = try await fixture.sha("feature")
            let feature = try fixture.branch("feature")
            await fixture.context.actions.performAndWait(.mergeIntoCurrentBranch(branch: "feature"))
            try await enterAhead(of: feature, expecting: .merge, fixture)

            // The place isn't entered again: its view and branch are the same.
            await fixture.context.actions.performAndWait(.squashAndMergeIntoCurrentBranch(branch: "feature"))
            #expect(fixture.repository.history.comparison.method == .squashMerge)
            #expect(fixture.context.state.history.branchView?.method == nil)
            await fixture.settle()
            await start(feature, fixture)
            try await expectRan(.squashMerge, fixture, m: m, f2: f2)
        }
    }

    @Test("closing the popover ends its pick, so it opens again to switch branches")
    func closingEndsThePick() async throws {
        let fixture = try await divergedFixture()
        let context = fixture.context
        await context.actions.performAndWait(.rebaseCurrentBranch(onto: nil))
        #expect(context.state.branchPopoverMethod == .rebase)

        await context.actions.performAndWait(.switchBranch)
        #expect(!context.state.isBranchPopoverPresented)
        await context.actions.performAndWait(.switchBranch)
        #expect(context.state.isBranchPopoverPresented)
        #expect(context.state.branchPopoverMethod == nil)
    }

    // MARK: Helpers

    /// Expects `branch`'s place selected on Ahead; enters it, as the screen
    /// does, and expects its comparison with the call to action on
    /// `method`, the request taken.
    private func enterAhead(
        of branch: Branch,
        expecting method: CompareMethod,
        _ fixture: OperationsFixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let context = fixture.context
        let place = SidebarPlace.branch(ref: branch.ref)
        try #require(context.state.place == place, sourceLocation: sourceLocation)
        #expect(context.state.history.view(forBranch: branch.ref) == .compare(.behind), sourceLocation: sourceLocation)
        await HistoryPlaces.enter(place, repository: fixture.repository, context: context)
        await fixture.settle()
        let comparison = fixture.repository.history.comparison
        #expect(comparison.branch?.ref == branch.ref, sourceLocation: sourceLocation)
        #expect(comparison.method == method, sourceLocation: sourceLocation)
        #expect(context.state.history.branchView?.method == nil, sourceLocation: sourceLocation)
    }

    /// Starts the call to action's method, as its split button does.
    private func start(_ branch: Branch, _ fixture: OperationsFixture, sourceLocation: SourceLocation = #_sourceLocation) async {
        let comparison = fixture.repository.history.comparison
        #expect(comparison.canStart, sourceLocation: sourceLocation)
        await MergeCallToActions.start(comparison.method, with: branch, repository: fixture.repository, context: fixture.context)
        await fixture.settle()
        #expect(fixture.presenter.error == nil, sourceLocation: sourceLocation)
        #expect(fixture.presenter.confirmation == nil, sourceLocation: sourceLocation)
    }

    /// Expects `main` to show `method` ran on M (`m`) and F2 (`f2`): a merge
    /// commit of both, one commit on M with F1's and F2's files, or M again
    /// on top of F2.
    private func expectRan(
        _ method: CompareMethod,
        _ fixture: OperationsFixture,
        m: String,
        f2: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let parents = JSCompat.trim(try await fixture.git(["rev-list", "--parents", "-n", "1", "main"]))
            .split(separator: " ")
            .dropFirst()
            .map(String.init)
        switch method {
        case .merge:
            #expect(parents == [m, f2], sourceLocation: sourceLocation)
        case .squashMerge:
            #expect(parents == [m], sourceLocation: sourceLocation)
            let files = try await fixture.git(["ls-tree", "--name-only", "main"]).split(separator: "\n").map(String.init)
            #expect(files.contains("F1.txt") && files.contains("F2.txt"), sourceLocation: sourceLocation)
        case .rebase:
            #expect(parents == [f2], sourceLocation: sourceLocation)
            #expect(try await fixture.summaries("main").first == "M", sourceLocation: sourceLocation)
        }
    }
}
