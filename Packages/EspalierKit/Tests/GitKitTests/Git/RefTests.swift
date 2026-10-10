// Ported from desktop/app/test/unit/git/ref-test.ts

import GitKit
import Testing
import TestSupport

@Suite("git/refs")
struct RefTests {
    @Suite("formatAsLocalRef")
    struct FormatAsLocalRef {
        @Test("formats a branch name as a local ref", arguments: [
            NamedCase("formats the common branch syntax", (name: "master", expected: "refs/heads/master")),
            NamedCase(
                "formats an explicit heads/ prefix",
                (name: "heads/something-important", expected: "refs/heads/something-important")
            ),
        ])
        func formats(_ testCase: NamedCase<(name: String, expected: String)>) {
            let result = formatAsLocalRef(testCase.value.name)
            #expect(result == testCase.value.expected)
        }
    }

    @Suite("getSymbolicRef")
    struct GetSymbolicRef {
        @Test("resolves a valid symbolic ref")
        func resolvesValidSymbolicRef() async throws {
            let repo = try setupEmptyRepository()
            let ref = try await getSymbolicRef(repo, "HEAD")
            #expect(ref == "refs/heads/master")
        }

        @Test("does not resolve a missing ref")
        func doesNotResolveMissingRef() async throws {
            let repo = try setupEmptyRepository()
            let ref = try await getSymbolicRef(repo, "FOO")
            #expect(ref == nil)
        }
    }
}
