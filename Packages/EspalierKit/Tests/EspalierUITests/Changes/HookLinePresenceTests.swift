// The composer's hook line shows once a hook has run 300 ms, so a quick hook
// never flashes it, and once shown it stays at least 1 s, past the commit's
// end if need be.

import EspalierCore
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Hook line presence", .hangGuard(minutes: 5)) @MainActor
struct HookLinePresenceTests {
    private let repository = RepositoryID(rawValue: UUID())
    private let scheduler = ManualScheduler()
    private let presence = HookLinePresence()

    private func update(_ name: String?, _ status: HookActivity.Status = .running, in repository: RepositoryID? = nil) {
        presence.update(
            name.map { HookActivity(name: $0, status: status) },
            output: nil,
            in: repository ?? self.repository,
            scheduler: scheduler
        )
    }

    @Test("a hook that ends within 300 ms never shows the line, while the commit goes on or after")
    func quickHook() async {
        update("post-commit")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(200))
        update("post-commit", .finished)
        await scheduler.advance(by: .milliseconds(500))
        #expect(presence.line == nil)
        update(nil)
        await scheduler.advance(by: .seconds(2))
        #expect(presence.line == nil)
    }

    @Test("a hook that runs 300 ms shows the line, which follows it and stays 1 s after the commit ends")
    func heldLine() async {
        update("pre-commit")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(299))
        #expect(presence.line == nil)
        await scheduler.advance(by: .milliseconds(1))
        #expect(presence.line?.hook == HookActivity(name: "pre-commit", status: .running))

        await scheduler.waitForSleepers(1)
        update("pre-commit", .finished)
        update(nil)
        await scheduler.advance(by: .milliseconds(999))
        #expect(presence.line?.hook == HookActivity(name: "pre-commit", status: .finished))
        await scheduler.advance(by: .milliseconds(1))
        #expect(presence.line == nil)
    }

    @Test("a line shown 1 s leaves as the commit ends")
    func lineAfterMinimum() async {
        update("pre-commit")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(300))
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))
        #expect(presence.line != nil)
        update(nil)
        #expect(presence.line == nil)
    }

    @Test("another repository drops the line at once")
    func otherRepository() async {
        update("pre-commit")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(300))
        #expect(presence.line != nil)
        update(nil, in: RepositoryID(rawValue: UUID()))
        #expect(presence.line == nil)
    }
}
