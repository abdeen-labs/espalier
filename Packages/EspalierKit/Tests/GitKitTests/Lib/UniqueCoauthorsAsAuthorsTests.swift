// Ported from desktop/app/test/unit/unique-coauthors-as-authors-test.ts

import Foundation
import GitKit
import Testing

/// A commit whose body ends with `trailers`, as git would find them.
private func buildTestCommit(_ trailers: [Trailer]) -> Commit {
    let author = CommitIdentity(name: "test", email: "test", date: Date())

    return Commit(
        sha: "test",
        shortSha: "test",
        summary: "test",
        body: (["test", ""] + trailers.map { "\($0.token): \($0.value)" }).joined(separator: "\n"),
        author: author,
        committer: author,
        parentSHAs: [],
        trailers: trailers,
        tags: []
    )
}

private func buildTestCoAuthorTrailer(_ email: String, _ name: String) -> Trailer {
    Trailer(token: "Co-Authored-By", value: "\(name) <\(email)>")
}

@Suite("getUniqueCoauthorsAsAuthors")
struct UniqueCoauthorsAsAuthorsTests {
    @Test("can returns empty array for no coauthors")
    func noCoauthors() {
        let trailers = [Trailer(token: "Signed-Off-By", value: "test <test@github.com>")]

        let commits = [
            buildTestCommit(trailers),
            buildTestCommit([]),
            buildTestCommit(trailers),
        ]

        let coAuthors = getUniqueCoauthorsAsAuthors(commits)
        #expect(coAuthors.count == 0)
    }

    @Test("does not return duplicate authors when name is different and email is the same")
    func differentNameSameEmail() {
        let email = "tidy-dev@github.com"
        let name = "tidy-dev"
        let trailers = [buildTestCoAuthorTrailer(email, name)]
        let trailersDiffName = [buildTestCoAuthorTrailer(email, name + "hello")]

        let commits = [
            buildTestCommit(trailers),
            buildTestCommit(trailers),
            buildTestCommit(trailersDiffName),
        ]

        let coAuthors = getUniqueCoauthorsAsAuthors(commits)
        #expect(coAuthors.count == 2)
    }

    @Test("does not return duplicate authors when email is different and name is the same")
    func differentEmailSameName() {
        let email = "tidy-dev@github.com"
        let otherEmail = "sergiou87@github.com"
        let name = "tidy-dev"
        let trailers = [buildTestCoAuthorTrailer(email, name)]
        let trailersDiffEmail = [buildTestCoAuthorTrailer(otherEmail, name)]

        let commits = [
            buildTestCommit(trailers),
            buildTestCommit(trailers),
            buildTestCommit(trailersDiffEmail),
        ]

        let coAuthors = getUniqueCoauthorsAsAuthors(commits)
        #expect(coAuthors.count == 2)
    }

    // MARK: - Espalier

    @Test("keeps the first occurrence, in order, with no username")
    func order() {
        let commits = [
            buildTestCommit([buildTestCoAuthorTrailer("b@example.com", "B"), buildTestCoAuthorTrailer("a@example.com", "A")]),
            buildTestCommit([buildTestCoAuthorTrailer("a@example.com", "A"), buildTestCoAuthorTrailer("c@example.com", "C")]),
        ]

        #expect(getUniqueCoauthorsAsAuthors(commits) == [
            KnownAuthor(name: "B", email: "b@example.com", username: nil),
            KnownAuthor(name: "A", email: "a@example.com", username: nil),
            KnownAuthor(name: "C", email: "c@example.com", username: nil),
        ])
    }
}
