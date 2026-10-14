import Foundation
import GitKit
import Testing

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

    @Test("extracts co-authors and removes the first occurrence of each from the body")
    func coAuthors() {
        let commit = makeCommit(
            body: "Body\n\nCo-Authored-By: Foo Bar <foo@bar.com>\nCo-Authored-By: Foo Bar <foo@bar.com>",
            trailers: [
                Trailer(token: "Co-Authored-By", value: "Foo Bar <foo@bar.com>"),
                Trailer(token: "Signed-off-by", value: "X <x@y>"),
                Trailer(token: "co-authored-by", value: "NoEmail"),
            ]
        )
        #expect(commit.coAuthors == [GitAuthor(name: "Foo Bar", email: "foo@bar.com")])
        #expect(commit.bodyNoCoAuthors == "Body\n\n\nCo-Authored-By: Foo Bar <foo@bar.com>")
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
