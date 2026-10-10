// The user's shell environment loads at launch, and operations wait for
// it, so git runs with the shell's variables, such as the `PATH` that finds
// `gpg` for signing.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Operations and the shell environment", .hangGuard(minutes: 5)) @MainActor
struct ShellEnvironmentWaitTests {
    @Test("an operation waits for the shell environment to load, then git runs with it")
    func waits() async throws {
        // The patience never runs out on a scheduler no one advances
        // (FinderLaunchHooksTests covers a shell that takes longer).
        let gate = AsyncGate()
        let shell = ShellEnvironment(scheduler: ManualScheduler()) {
            await gate.wait()
            return ["ESPALIER_FROM_SHELL": "yes"]
        }
        var runtime = GitRuntime.current
        runtime.shellEnvironment = shell
        let harness = try AppHarness(git: runtime)
        let app = await harness.loadedApp()
        let repository = try setupEmptyRepository()
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        let model = try #require(app.repository(id))
        await app.idle()

        let started = AsyncEvent<Void>()
        let operation = Task { @MainActor in
            started.resolve()
            return try await model.perform(OperationDescriptor(kind: .commit)) { _ in
                try await git(["-c", "alias.e=!printenv ESPALIER_FROM_SHELL", "e"], repository.path, "printenv").stdout
            }
        }
        // The operation keeps the main actor until it waits for the
        // environment, so once this test runs again, it has started (the
        // suite's hang guard fails a run where it never does). It goes no
        // further while the environment loads.
        try await started.wait()
        #expect(model.operationsInFlight == 1)
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(shell.variables == nil)

        gate.open()
        #expect(try await operation.value == "yes\n")
        await app.idle()
    }
}
