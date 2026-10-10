// The Branches section's rows load how their branches compare with their
// upstreams while they're on screen (BranchesSection.swift's
// `UpstreamStateWatcher`).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch rows' upstream states", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchUpstreamStateRowsTests {
    @Test("rows on screen load their branches' upstream states; remote and unpublished rows don't ask")
    func rowsLoadStates() async throws {
        let fixture = try await makeOperationsFixture { local in
            // ahead: one commit not on its upstream.
            try await runGit(["checkout", "-b", "ahead"], local)
            try await runGit(["push", "-u", "origin", "ahead"], local)
            try await commitFile(local, "ahead.txt", "ahead\n")
            // unpublished: no upstream.
            try await runGit(["checkout", "-b", "unpublished", "main"], local)
            // remote-only: on origin, with no local branch.
            try await runGit(["push", "origin", "unpublished:remote-only"], local)
            try await runGit(["checkout", "main"], local)
        }
        let repository = fixture.repository
        let content = BranchesSectionContent.make(repository, upstreamStates: [:], filter: "")
        #expect(content.allRows.map(\.ref).contains("refs/remotes/origin/remote-only"))
        let host = NSHostingView(rootView: List {
            BranchesSectionRows(content: content, repository: repository)
            // The remote group's rows, open.
            ForEach(content.remotes) { remote in
                BranchNodeList(nodes: remote.nodes, repository: repository, isFiltering: true)
            }
        }
        .windowEnvironment(fixture.context))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        await waitUntil { repository.branches.upstreamStates["refs/heads/ahead"] != nil }
        await repository.branches.upstreamStatesIdle()
        #expect(repository.branches.upstreamStatesLoader.watchedRefs == ["refs/heads/main", "refs/heads/ahead"])
        #expect(repository.branches.upstreamStates == [
            "refs/heads/main": .tracking(AheadBehind(ahead: 0, behind: 0)),
            "refs/heads/ahead": .tracking(AheadBehind(ahead: 1, behind: 0)),
        ])
        await fixture.app.idle()
    }
}
