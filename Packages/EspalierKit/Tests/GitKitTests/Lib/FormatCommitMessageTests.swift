// Ported from desktop/app/test/unit/format-commit-message-test.ts

import GitKit
import Testing
import TestSupport

@Suite("formatCommitMessage")
struct FormatCommitMessageTests {
    static let signedOffBy = Trailer(token: "Signed-Off-By", value: "nerdneha <nerdneha@github.com>")
    static let trailers = [
        Trailer(token: "Co-Authored-By", value: "Markus Olsson <niik@github.com>"),
        signedOffBy,
    ]

    @Test("formats the summary, description, and trailers", arguments: formatCases)
    func formats(_ testCase: NamedCase<(context: CommitContext, expected: String)>) async throws {
        let repo = try setupEmptyRepository()
        #expect(try await formatCommitMessage(repo, testCase.value.context) == testCase.value.expected)
    }

    static let formatCases: [NamedCase<(context: CommitContext, expected: String)>] = [
        NamedCase("always adds trailing newline", (
            context: CommitContext(summary: "test", description: nil),
            expected: "test\n"
        )),
        NamedCase("omits description when empty string", (
            context: CommitContext(summary: "test", description: ""),
            expected: "test\n"
        )),
        NamedCase("adds two newlines between summary and description", (
            context: CommitContext(summary: "foo", description: "bar"),
            expected: "foo\n\nbar\n"
        )),
        NamedCase("appends trailers to a summary-only message", (
            context: CommitContext(summary: "foo", description: nil, trailers: trailers),
            expected: """
                foo

                Co-Authored-By: Markus Olsson <niik@github.com>
                Signed-Off-By: nerdneha <nerdneha@github.com>

                """
        )),
        NamedCase("appends trailers to a regular message", (
            context: CommitContext(summary: "foo", description: "bar", trailers: trailers),
            expected: """
                foo

                bar

                Co-Authored-By: Markus Olsson <niik@github.com>
                Signed-Off-By: nerdneha <nerdneha@github.com>

                """
        )),
        // note, this relies on the default git config
        NamedCase("merges duplicate trailers", (
            context: CommitContext(summary: "foo", description: "Co-Authored-By: Markus Olsson <niik@github.com>", trailers: trailers),
            expected: """
                foo

                Co-Authored-By: Markus Olsson <niik@github.com>
                Signed-Off-By: nerdneha <nerdneha@github.com>

                """
        )),
        // note, this relies on the default git config
        NamedCase("fixes up malformed trailers when trailers are given", (
            context: CommitContext(
                summary: "foo",
                // note the lack of space after :
                description: "Co-Authored-By:Markus Olsson <niik@github.com>",
                trailers: [signedOffBy]
            ),
            expected: """
                foo

                Co-Authored-By: Markus Olsson <niik@github.com>
                Signed-Off-By: nerdneha <nerdneha@github.com>

                """
        )),
        // note, this relies on the default git config
        NamedCase("doesn't treat --- as end of commit message", (
            context: CommitContext(
                summary: "foo",
                description: "hello\n---\nworld\n\nCo-Authored-By: Markus Olsson <niik@github.com>",
                trailers: [signedOffBy]
            ),
            expected: """
                foo

                hello
                ---
                world

                Co-Authored-By: Markus Olsson <niik@github.com>
                Signed-Off-By: nerdneha <nerdneha@github.com>

                """
        )),
    ]

    // MARK: - Espalier

    @Test("trims JavaScript whitespace at the end, and keeps it elsewhere")
    func trailingWhitespace() async throws {
        let repo = try setupEmptyRepository()
        #expect(try await formatCommitMessage(repo, CommitContext(summary: "", description: "")) == "\n")
        #expect(try await formatCommitMessage(repo, CommitContext(summary: "sum  ", description: "desc \u{A0}\n\n")) == "sum  \n\ndesc\n")
        #expect(try await formatCommitMessage(repo, CommitContext(summary: "sum", description: "\u{2028}")) == "sum\n")
        #expect(
            try await formatCommitMessage(repo, CommitContext(summary: "  caf\u{E9}", description: "  \u{FC}n\u{EF}code"))
                == "  caf\u{E9}\n\n  \u{FC}n\u{EF}code\n"
        )
    }

    @Test("an empty list of trailers leaves the message alone")
    func emptyTrailers() async throws {
        let repo = try setupEmptyRepository()
        #expect(try await formatCommitMessage(repo, CommitContext(summary: "foo", description: "Bar: baz", trailers: [])) == "foo\n\nBar: baz\n")
    }
}
