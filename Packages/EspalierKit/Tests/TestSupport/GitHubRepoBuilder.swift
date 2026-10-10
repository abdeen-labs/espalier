// Ported from desktop/app/test/helpers/github-repo-builder.ts

import GitHubKit
import Synchronization

private let idCounter = Mutex(0)

private func nextID() -> Int {
    idCounter.withLock { id in
        defer { id += 1 }
        return id
    }
}

/// Makes a fairly standard `GitHubRepository` for use in tests.
/// Ensures a unique `dbID` for each, during a test run.
///
/// `endpoint` defaults to github.com if omitted. We make an attempt at
/// constructing a meaningful non-github.com clone url and html url from this,
/// even if its ''.
public func gitHubRepoFixture(
    owner: String,
    name: String,
    parent: GitHubRepository? = nil,
    endpoint: String? = nil,
    isPrivate: Bool? = nil
) -> GitHubRepository {
    let htmlUrl = "\(endpoint ?? "https://github.com")/\(owner)/\(name)"
    return GitHubRepository(
        name: name,
        owner: Owner(login: owner, endpoint: endpoint ?? getDotComAPIEndpoint(), id: nextID()),
        dbID: nextID(),
        isPrivate: isPrivate,
        htmlURL: htmlUrl,
        cloneURL: "\(htmlUrl).git",
        issuesEnabled: nil,
        isArchived: nil,
        permissions: nil,
        parent: parent
    )
}
