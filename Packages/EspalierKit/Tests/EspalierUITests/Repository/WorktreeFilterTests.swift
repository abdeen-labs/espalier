// The repository popover's filter keeps the worktrees whose folder name or
// branch it matches, the same fuzzy way it keeps repositories.

import GitKit
import Testing
@testable import EspalierUI

@Suite("The repository popover's worktree filter")
struct WorktreeFilterTests {
    private static let worktrees = [
        WorktreeEntry(
            path: "/Users/joe/Developer/espalier", head: String(repeating: "a", count: 40), branch: "refs/heads/main",
            isDetached: false, type: .main, isLocked: false, isPrunable: false
        ),
        WorktreeEntry(
            path: "/Users/joe/Developer/espalier-login", head: String(repeating: "b", count: 40), branch: "refs/heads/feature/login",
            isDetached: false, type: .linked, isLocked: false, isPrunable: false
        ),
        WorktreeEntry(
            path: "/Users/joe/Developer/scratch", head: String(repeating: "c", count: 40), branch: nil,
            isDetached: true, type: .linked, isLocked: false, isPrunable: false
        ),
    ]

    private func names(_ filter: String) -> [String] {
        WorktreeRowContent.rows(Self.worktrees, currentPath: nil, filter: filter).map(\.name)
    }

    @Test("matches a name's or a branch's characters in order, ignoring case, keeping git's order")
    func fuzzy() {
        #expect(names("") == ["espalier", "espalier-login", "scratch"])
        // By folder name, its letters in order.
        #expect(names("eslgn") == ["espalier-login"])
        #expect(names("ESPALIER") == ["espalier", "espalier-login"])
        // By branch, its separators optional.
        #expect(names("feature login") == ["espalier-login"])
        #expect(names("mn") == ["espalier"])
        // By a detached worktree's short SHA.
        #expect(names("ccc") == ["scratch"])
        #expect(names("zzz").isEmpty)
    }
}
