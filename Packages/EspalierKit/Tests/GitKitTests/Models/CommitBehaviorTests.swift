import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Commit behavior")
struct CommitBehaviorTests {
    @Test("parses name-address pairs")
    func gitAuthorParse() {
        let author = GitAuthor.parse("Foo Bar <foo@bar.com>")
        #expect(author == GitAuthor(name: "Foo Bar", email: "foo@bar.com"))
        #expect(author?.description == "Foo Bar <foo@bar.com>")
        #expect(GitAuthor.parse("NoEmail") == nil)
        #expect(GitAuthor.parse("A<b>") == nil)
        #expect(GitAuthor.parse("A <b") == nil)
        // JavaScript's \s matches newlines and no-break spaces, but not U+0085.
        #expect(GitAuthor.parse("Foo\n<bar>") == GitAuthor(name: "Foo", email: "bar"))
        #expect(GitAuthor.parse("A\u{A0}<b>") == GitAuthor(name: "A", email: "b"))
        #expect(GitAuthor.parse("A\u{85}<b>") == nil)
        #expect(GitAuthor.parse("A <b> <c>") == GitAuthor(name: "A", email: "b"))
        #expect(GitAuthor.parse(" <x>") == GitAuthor(name: "", email: "x"))
    }

    @Test("compares author and committer code unit by code unit")
    func authoredByCommitter() {
        let precomposed = identity("\u{E9}", "a")
        #expect(makeCommit(author: precomposed, committer: identity("\u{E9}", "a")).authoredByCommitter)
        // Canonically equivalent but different code units.
        #expect(!makeCommit(author: precomposed, committer: identity("e\u{301}", "a")).authoredByCommitter)
        #expect(!makeCommit(author: identity("A", "a"), committer: identity("A", "b")).authoredByCommitter)
    }

    @Test("parses identities like desktop at the edges")
    func identityEdges() throws {
        let unsigned = try CommitIdentity.parseIdentity("A <b> 0 0130")
        #expect(unsigned.date == Date(timeIntervalSince1970: 0))

        // The latest date a JavaScript Date can hold, and one second past it.
        let latest = try CommitIdentity.parseIdentity("A <b> 8640000000000 +0000")
        #expect(latest.date == Date(timeIntervalSince1970: 8_640_000_000_000))
        #expect(throws: ModelError("Couldn't parse identity A <b> 8640000000001 +0000, invalid date")) {
            try CommitIdentity.parseIdentity("A <b> 8640000000001 +0000")
        }

        // \d only matches ASCII digits.
        #expect(throws: ModelError("Couldn't parse identity A <b> \u{661}\u{662} +0000")) {
            try CommitIdentity.parseIdentity("A <b> \u{661}\u{662} +0000")
        }

        // Trailing text after the time zone is ignored.
        let trailing = try CommitIdentity.parseIdentity("A <b> 1475670580 +0200 trailing")
        #expect(trailing.description == "A <b>")
    }

    private func identity(_ name: String, _ email: String) -> CommitIdentity {
        CommitIdentity(name: name, email: email, date: Date(timeIntervalSince1970: 0))
    }

    private func makeCommit(
        body: String = "",
        trailers: [Trailer] = [],
        author: CommitIdentity? = nil,
        committer: CommitIdentity? = nil
    ) -> Commit {
        let author = author ?? identity("A", "a@x")
        return Commit(
            sha: "sha",
            shortSha: "short",
            summary: "summary",
            body: body,
            author: author,
            committer: committer ?? author,
            parentSHAs: ["p"],
            trailers: trailers,
            tags: []
        )
    }
}

/// The co-authors git finds in a message's body, and the body without
/// them.
typealias CoAuthorTrailersCase = (body: String, coAuthors: [String], bodyNoCoAuthors: String)

// Commits written with git and read back with `getCommit`, so git decides
// what's a trailer.
@Suite("Co-author trailers")
struct CoAuthorTrailersTests {
    @Test("only co-author trailers that are Name <email> leave the body, each once", arguments: [
        NamedCase("an email alone stays in the body", (
            body: "Paired.\n\nCo-authored-by: bob@example.com\nCo-authored-by: Alice <alice@example.com>\n",
            coAuthors: ["Alice <alice@example.com>"],
            bodyNoCoAuthors: "Paired.\n\nCo-authored-by: bob@example.com\n"
        )),
        NamedCase("no space after the colon", (
            body: "Paired.\n\nCo-authored-by:Alice <alice@example.com>\n",
            coAuthors: ["Alice <alice@example.com>"],
            bodyNoCoAuthors: "Paired.\n\n"
        )),
        NamedCase("other trailers stay as written", (
            body: "Signed-off-by:Bob <bob@example.com>\nco-authored-by :  Alice <alice@example.com>\nReviewed-by: Carol\n",
            coAuthors: ["Alice <alice@example.com>"],
            bodyNoCoAuthors: "Signed-off-by:Bob <bob@example.com>\nReviewed-by: Carol\n"
        )),
        NamedCase("a folded trailer, with its continuation line", (
            body: "Paired.\n\nCo-authored-by: Alice\n  <alice@example.com>\nSigned-off-by: Bob <bob@example.com>\n",
            coAuthors: ["Alice <alice@example.com>"],
            bodyNoCoAuthors: "Paired.\n\nSigned-off-by: Bob <bob@example.com>\n"
        )),
        NamedCase("the same line in an earlier paragraph stays", (
            body: "Co-authored-by: Alice <alice@example.com>\nwrote this line.\n\nCo-authored-by: Alice <alice@example.com>\n",
            coAuthors: ["Alice <alice@example.com>"],
            bodyNoCoAuthors: "Co-authored-by: Alice <alice@example.com>\nwrote this line.\n\n"
        )),
        NamedCase("not a trailer block", (
            body: "Co-authored-by: Alice <alice@example.com> helped,\nas this paragraph says.\n",
            coAuthors: [],
            bodyNoCoAuthors: "Co-authored-by: Alice <alice@example.com> helped,\nas this paragraph says.\n"
        )),
    ] as [NamedCase<CoAuthorTrailersCase>])
    func coAuthors(_ testCase: NamedCase<CoAuthorTrailersCase>) async throws {
        let repository = try setupEmptyRepository()
        let commit = try await commitMessage("Summary\n\n\(testCase.value.body)", in: repository)
        #expect(commit.body == testCase.value.body)
        #expect(commit.coAuthors.map(\.description) == testCase.value.coAuthors)
        #expect(commit.bodyNoCoAuthors == testCase.value.bodyNoCoAuthors)
    }

    @Test("a squash keeps a co-author that isn't Name <email> in the description, and adds each other one once")
    func squash() async throws {
        let repository = try setupEmptyRepository()
        let target = try await commitMessage("Base\n", in: repository)
        let first = try await commitMessage("One\n\nCo-authored-by: bob@example.com\n", in: repository)
        let second = try await commitMessage("Two\n\nCo-authored-by:Hubot <hubot@example.com>\n", in: repository)

        // The squash's message, as the squash sheet writes it.
        let coAuthors = getUniqueCoauthorsAsAuthors([first, second, target])
        let message = try await formatCommitMessage(repository, CommitContext(
            summary: target.summary,
            description: getSquashedCommitDescription([first, second], target),
            trailers: coAuthors.map { Trailer(token: "Co-Authored-By", value: "\($0.name) <\($0.email)>") }
        ))
        #expect(message == "Base\n\nOne\n\nCo-authored-by: bob@example.com\n\nTwo\n\nCo-Authored-By: Hubot <hubot@example.com>\n")
    }

    /// Commits `message` as is (with an empty commit) and reads it back.
    private func commitMessage(_ message: String, in repository: Repository) async throws -> Commit {
        try await git(
            ["commit", "--allow-empty", "--cleanup=verbatim", "-F", "-"],
            repository.path,
            "commitMessage",
            options: GitExecutionOptions(stdin: message)
        )
        return try #require(try await getCommit(repository, "HEAD"))
    }
}
