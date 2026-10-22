// A folder typed into a field: a leading `~`, alone or before a `/`, is the
// home folder; anything else stays as typed.

@testable import EspalierCore
import Testing
import TestSupport

@Suite("Typed paths")
struct TypedPathTests {
    @Test("a leading ~ is the home folder", arguments: [
        NamedCase("~ alone", (typed: "~", expanded: "/Users/joe")),
        NamedCase("~ before a folder", (typed: "~/Developer/app", expanded: "/Users/joe/Developer/app")),
        NamedCase("~ with a trailing separator", (typed: "~/", expanded: "/Users/joe/")),
        NamedCase("another user's home", (typed: "~joe/Developer", expanded: "~joe/Developer")),
        NamedCase("a full path", (typed: "/Users/joe/~/app", expanded: "/Users/joe/~/app")),
        NamedCase("a relative path", (typed: "Developer/~", expanded: "Developer/~")),
        NamedCase("nothing", (typed: "", expanded: "")),
    ] as [NamedCase<(typed: String, expanded: String)>])
    func expanding(_ testCase: NamedCase<(typed: String, expanded: String)>) {
        #expect(expandingTilde(testCase.value.typed, home: "/Users/joe") == testCase.value.expanded)
    }
}
