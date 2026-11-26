// When Home shows a step as running (Push All, a card's Push and Clean Up):
// only while a run the user agreed to goes. A step that always asks first
// isn't running while it reads what to ask, while it asks, or after a
// Cancel; once confirmed it is until it ends. A step that needs no
// confirmation runs from the click, and stops showing while something it
// asks partway waits.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

/// Every running state a step reported, in order.
@MainActor
private final class RunningLog {
    private(set) var states: [Bool] = []

    var isRunning: Bool {
        states.last ?? false
    }

    func record(_ isRunning: Bool) {
        states.append(isRunning)
    }
}

@Suite("Home step running", .offline, .hangGuard(minutes: 5)) @MainActor
struct HomeStepRunningTests {
    private func makeContext() async throws -> (AppHarness, WindowContext) {
        let harness = try AppHarness(showsHome: true)
        let app = await harness.loadedApp()
        return (harness, WindowContext(app: app))
    }

    private func confirmation(of presenter: WindowPresenter) async -> PendingConfirmation {
        await waitUntil { presenter.confirmation != nil }
        return presenter.confirmation!
    }

    private let asked = OperationError(.confirmationRequired(.pushAll([])), operation: .push)

    @Test("a step that asks first isn't running while it asks, nor after a Cancel")
    func cancelledBeforeRunning() async throws {
        let (_, context) = try await makeContext()
        let log = RunningLog()
        let asked = asked
        let step = Task {
            await HomeSteps.perform(asksFirst: true, in: context, setRunning: log.record) { answers throws(OperationError) -> Bool in
                guard answers.confirmed.contains(.pushAll) else {
                    throw asked
                }
                return true
            }
        }

        let pending = await confirmation(of: context.presenter)
        #expect(log.states.isEmpty)
        context.presenter.respond(to: pending.id, with: .cancelled)
        #expect(await step.value == nil)
        #expect(log.states.isEmpty)
    }

    @Test("a step that asks first is running once confirmed, until it ends")
    func runningOnceConfirmed() async throws {
        let (_, context) = try await makeContext()
        let log = RunningLog()
        let started = AsyncEvent<Void>()
        let release = AsyncEvent<Void>()
        let asked = asked
        let step = Task {
            await HomeSteps.perform(asksFirst: true, in: context, setRunning: log.record) { answers throws(OperationError) -> Bool in
                guard answers.confirmed.contains(.pushAll) else {
                    throw asked
                }
                started.resolve()
                try? await release.wait()
                return true
            }
        }

        let pending = await confirmation(of: context.presenter)
        #expect(log.states.isEmpty)
        context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
        try await started.wait()
        #expect(log.isRunning)
        release.resolve()
        #expect(await step.value == true)
        #expect(log.states == [true, false])
    }

    @Test("a step that needs no confirmation runs from the click, and isn't running while it asks partway")
    func runsFromTheClick() async throws {
        let (_, context) = try await makeContext()
        let log = RunningLog()
        let asking = AsyncEvent<Void>()
        let asked = asked
        let step = Task {
            await HomeSteps.perform(asksFirst: false, in: context, setRunning: log.record) { answers throws(OperationError) -> Bool in
                guard answers.confirmed.contains(.pushAll) else {
                    #expect(log.isRunning)
                    asking.resolve()
                    throw asked
                }
                return true
            }
        }

        try await asking.wait()
        let pending = await confirmation(of: context.presenter)
        #expect(!log.isRunning)
        context.presenter.respond(to: pending.id, with: .cancelled)
        #expect(await step.value == nil)
        #expect(log.states == [true, false])
    }
}
