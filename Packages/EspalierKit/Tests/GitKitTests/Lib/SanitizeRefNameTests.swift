// Ported from desktop/app/test/unit/sanitize-ref-name-test.ts

import GitKit
import Testing
import TestSupport

@Suite("sanitizedBranchName")
struct SanitizeRefNameTests {
    @Test("sanitizes branch names", arguments: [
        NamedCase("leaves a good branch name alone", (branchName: "this-is/fine", expected: "this-is/fine")),
        NamedCase("replaces invalid characters with dashes", (branchName: ".this..is\\not fine:yo?|is-it", expected: "this-is-not-fine-yo-is-it")),
        NamedCase("does not allow branch name to end in slash", (branchName: "hello/", expected: "hello-")),
        NamedCase("does not allow name to start with plus", (branchName: "++but-can-still-keep-the-rest", expected: "but-can-still-keep-the-rest")),
        NamedCase("does not allow name to start with minus", (branchName: "--but-can-still-keep-the-rest", expected: "but-can-still-keep-the-rest")),
        NamedCase("does not allow name to end in `.lock`", (branchName: "foo.lock.lock", expected: "foo.lock-")),
        NamedCase("removes starting dot", (branchName: ".first.dot.is.not.ok", expected: "first.dot.is.not.ok")),
        NamedCase("allows double dashes after first character", (branchName: "branch--name", expected: "branch--name")),
    ])
    func sanitizes(_ testCase: NamedCase<(branchName: String, expected: String)>) {
        #expect(sanitizedRefName(testCase.value.branchName) == testCase.value.expected)
    }

    // MARK: - Espalier

    @Test("replaces the other invalid sequences, and keeps non-ASCII text")
    func otherSequences() {
        #expect(sanitizedRefName("a@{b") == "a-b")
        #expect(sanitizedRefName("a~b^c*d[e]f\"g<h>i") == "a-b-c-d-e]f-g-h-i")
        #expect(sanitizedRefName("trailing.") == "trailing-")
        #expect(sanitizedRefName("tab\there\u{7F}") == "tab-here-")
        #expect(sanitizedRefName("f\u{EB}ature/caf\u{E9}") == "f\u{EB}ature/caf\u{E9}")
        // Only the end of the whole name counts, not of a line.
        #expect(sanitizedRefName("a.lock\n") == "a.lock-")
    }

    // Git applies its rules to each `/`-separated component, and refuses
    // empty components: the sanitized name is one git creates a branch and
    // a tag with.
    @Test("applies git's rules to each component of the name", arguments: [
        NamedCase("collapses slashes in a row", (name: "feature//x", expected: "feature/x")),
        NamedCase("removes a leading slash", (name: "/foo", expected: "foo")),
        NamedCase("replaces a dot starting a component", (name: "feature/.x", expected: "feature/-x")),
        NamedCase("replaces .lock ending a component", (name: "a.lock/b", expected: "a-/b")),
        NamedCase("replaces a component's leading dot before .lock", (name: "a/.lock", expected: "a/-lock")),
        NamedCase("replaces a dot left at the start", (name: "~.a", expected: "a")),
    ])
    func componentRules(_ testCase: NamedCase<(name: String, expected: String)>) async throws {
        let sanitized = sanitizedRefName(testCase.value.name)
        #expect(sanitized == testCase.value.expected)

        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")]))
        try await GitKit.createBranch(repository, sanitized, nil)
        try await createTag(repository, sanitized, "HEAD")
    }

    // Sheets sanitize the name as it's typed. Each `-.` here leaves a dot at
    // the start once the dash before it goes, so a name sanitized again
    // until it stops changing takes minutes.
    @Test("sanitizes a long name in time proportional to its length", .timeLimit(.minutes(1)))
    func longName() {
        #expect(sanitizedRefName(String(repeating: "-.", count: 50_000) + "a") == "a")
    }

    @Test("leaves nothing of HEAD, which git refuses as a branch or tag name")
    func head() {
        #expect(sanitizedRefName("HEAD") == "")
        #expect(sanitizedRefName("-HEAD") == "")
        #expect(sanitizedRefName("feature/HEAD") == "feature/HEAD")
    }

    // A global regex keeps `lastIndex` after a match, so its next test
    // would start searching where the previous match ended.
    @Test("testForInvalidChars rejects every invalid name, one after another")
    func testForInvalidCharsHasNoState() {
        #expect(testForInvalidChars("a..b") == true)
        // A stateful regex would say false, resuming the search at index 3.
        #expect(testForInvalidChars("..ab") == true)
        #expect(testForInvalidChars("..ab") == true)
        #expect(testForInvalidChars("fine") == false)
    }
}
