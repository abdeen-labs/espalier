// VoiceOver hears a filter's results a second after its text stops
// changing: typing again starts the wait over, clearing the filter or the
// view going away cancels it, and results still loading are announced once
// they're in.

import Observation
import Testing
import TestSupport
@testable import EspalierUI

/// A list whose results load later.
@MainActor @Observable
private final class LoadingResults {
    var count: Int?
}

@Suite("Filter results announcements", .hangGuard(minutes: 5)) @MainActor
struct FilterResultsAnnouncerTests {
    @Test("the results are announced once the text has been still for a second; typing again starts the wait over")
    func announcedAfterDelay() async {
        let scheduler = ManualScheduler()
        let recorded = RecordedAnnouncements()
        let filter = FilterResultsAnnouncer()

        filter.filterChanged(to: "ma", count: { 12 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(900))
        #expect(recorded.messages.isEmpty)

        // Typing again: the second counts from the new text.
        filter.filterChanged(to: "mai", count: { 1 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(900))
        #expect(recorded.messages.isEmpty)
        await scheduler.advance(by: .milliseconds(100))
        #expect(recorded.messages.count == 1)

        filter.filterChanged(to: "m", count: { 1_234 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))
        #expect(recorded.messages.count == 2)
    }

    @Test("clearing the filter or the view going away cancels the wait, and an empty filter says nothing")
    func cancelled() async {
        let scheduler = ManualScheduler()
        let recorded = RecordedAnnouncements()
        let filter = FilterResultsAnnouncer()

        filter.filterChanged(to: "x", count: { 0 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(500))
        filter.filterChanged(to: "", count: { 3 }, scheduler: scheduler, announcer: recorded.announcer)
        #expect(scheduler.sleeperCount == 0)
        await scheduler.advance(by: .seconds(2))
        #expect(recorded.messages.isEmpty)

        filter.filterChanged(to: "x", count: { 0 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        filter.cancel()
        await scheduler.advance(by: .seconds(2))
        #expect(recorded.messages.isEmpty)

        filter.filterChanged(to: "x", count: { 0 }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))
        #expect(recorded.messages.count == 1)
    }

    @Test("results still loading when the wait ends are announced once they're in")
    func loadingResults() async {
        let scheduler = ManualScheduler()
        let recorded = RecordedAnnouncements()
        let filter = FilterResultsAnnouncer()
        let results = LoadingResults()

        filter.filterChanged(to: "fix", count: { results.count }, scheduler: scheduler, announcer: recorded.announcer)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))
        #expect(recorded.messages.isEmpty)

        results.count = 3
        await waitUntil { !recorded.messages.isEmpty }
        #expect(recorded.messages.count == 1)
    }
}
