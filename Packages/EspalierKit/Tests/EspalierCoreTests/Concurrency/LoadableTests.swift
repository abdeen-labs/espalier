@testable import EspalierCore
import Testing

private struct LoadFailure: Error, Equatable {
    let message: String
}

private typealias Diff = Loadable<String, LoadFailure>

@Suite("Loadable")
struct LoadableTests {
    @Test("reloading keeps the value shown, and drops a failure")
    func reloading() {
        #expect(Diff.loaded("shown").reloading == .loading(previous: "shown"))
        #expect(Diff.loading(previous: "shown").reloading == .loading(previous: "shown"))
        #expect(Diff.loading(previous: nil).reloading == .loading(previous: nil))
        #expect(Diff.idle.reloading == .loading(previous: nil))
        #expect(Diff.failed(LoadFailure(message: "bad")).reloading == .loading(previous: nil))
    }

    @Test("map transforms the value in each state that has one")
    func map() {
        let count: (String) -> Int = { $0.count }
        #expect(Diff.idle.map(count) == .idle)
        #expect(Diff.loading(previous: nil).map(count) == .loading(previous: nil))
        #expect(Diff.loading(previous: "four").map(count) == .loading(previous: 4))
        #expect(Diff.loaded("three").map(count) == .loaded(5))
        #expect(Diff.failed(LoadFailure(message: "bad")).map(count) == .failed(LoadFailure(message: "bad")))
    }

    @Test("a transform that throws gives the failure")
    func mapThrows() {
        let failure = LoadFailure(message: "unreadable")
        let transform: (String) throws(LoadFailure) -> Int = { _ in throw failure }
        #expect(Diff.loaded("value").map(transform) == .failed(failure))
        #expect(Diff.loading(previous: "value").map(transform) == .failed(failure))

        // Without a value there is nothing to transform.
        #expect(Diff.loading(previous: nil).map(transform) == .loading(previous: nil))
        #expect(Diff.idle.map(transform) == .idle)
    }
}
