// Ported from desktop/app/src/lib/unique-coauthors-as-authors.ts

import EspalierSupport

/// The co-authors of the given commits, each name and email pair once, in
/// the order they first appear, as known authors without a username.
public func getUniqueCoauthorsAsAuthors(_ commits: [Commit]) -> [KnownAuthor] {
    let allCommitsCoAuthors = commits.flatMap(\.coAuthors)

    // Keeps the first of each group of equal values.
    var uniqueCoAuthors: [GitAuthor] = []
    for coAuthor in allCommitsCoAuthors {
        let seen = uniqueCoAuthors.contains { other in
            JSCompat.strictEquals(other.email, coAuthor.email) && JSCompat.strictEquals(other.name, coAuthor.name)
        }
        if !seen {
            uniqueCoAuthors.append(coAuthor)
        }
    }

    return uniqueCoAuthors.map { ca in
        KnownAuthor(name: ca.name, email: ca.email, username: nil)
    }
}
