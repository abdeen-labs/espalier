// Ported from desktop/app/test/unit/squashed-commit-description-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

private let mockCoAuthorTrailers = [Trailer(token: "Co-Authored-By", value: "test <test>")]

/// The commits squashed, in order, the commit they're squashed onto, and the
/// expected description: each as (summary, body, trailers).
typealias SquashedCommitDescriptionCase = (
    commits: [(summary: String, body: String, trailers: [Trailer])],
    squashOnto: (summary: String, body: String, trailers: [Trailer]),
    expected: String
)

@Suite("getSquashedCommitDescription")
struct SquashedCommitDescriptionTests {
    @Test("builds squashed commit descriptions", arguments: [
        NamedCase("builds squashed commit descriptions - no coauthors provided", (
            commits: [("summary1", "desc1", []), ("summary2", "desc2", [])],
            squashOnto: ("ontoSummary", "ontoDesc", []),
            expected: "ontoDesc\n\nsummary1\n\ndesc1\n\nsummary2\n\ndesc2"
        )),
        NamedCase("builds squashed commit descriptions with whitespace trimmed", (
            commits: [("summary1    ", "desc1   ", mockCoAuthorTrailers), ("summary2\n", "desc2\n", mockCoAuthorTrailers)],
            squashOnto: ("ontoSummary", "ontoDesc  \n", mockCoAuthorTrailers),
            expected: "ontoDesc\n\nsummary1\n\ndesc1\n\nsummary2\n\ndesc2"
        )),
        // The co-authors in a body.
        NamedCase("removes co-author trailers found in the bodies", (
            commits: [
                ("summary1", "desc1\n\nCo-Authored-By: Jane <jane@example.com>", [Trailer(token: "Co-Authored-By", value: "Jane <jane@example.com>")]),
                ("summary2", "Co-Authored-By: Jane <jane@example.com>", [Trailer(token: "Co-Authored-By", value: "Jane <jane@example.com>")]),
            ],
            squashOnto: ("ontoSummary", "", []),
            expected: "summary1\n\ndesc1\n\nsummary2\n\n"
        )),
    ] as [NamedCase<SquashedCommitDescriptionCase>])
    func builds(_ testCase: NamedCase<SquashedCommitDescriptionCase>) {
        let (commits, squashOnto, expected) = testCase.value
        let desc = getSquashedCommitDescription(
            commits.map { buildTestCommit($0.summary, $0.body, $0.trailers) },
            buildTestCommit(squashOnto.summary, squashOnto.body, squashOnto.trailers)
        )
        #expect(desc == expected)
    }

    private func buildTestCommit(_ summary: String, _ body: String, _ trailers: [Trailer]) -> Commit {
        let author = CommitIdentity(name: "test", email: "test", date: Date())

        return Commit(
            sha: "test",
            shortSha: "test",
            summary: summary,
            body: body,
            author: author,
            committer: author,
            parentSHAs: [],
            trailers: trailers,
            tags: []
        )
    }
}
