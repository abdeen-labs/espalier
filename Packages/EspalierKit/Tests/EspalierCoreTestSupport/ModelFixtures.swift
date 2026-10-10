import EspalierCore
import Foundation
import GitHubKit
import GitKit

/// Model values with sensible defaults.
public enum ModelFixtures {
    /// A repository record.
    public static func record(
        id: RepositoryID = RepositoryID(),
        path: String = "/Users/me/src/app",
        alias: String? = nil,
        isMissing: Bool = false,
        gitHubRepository: GitHubRepository? = nil
    ) -> RepositoryRecord {
        RepositoryRecord(
            id: id,
            path: path,
            alias: alias,
            isMissing: isMissing,
            gitHubRepository: gitHubRepository,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// A branch.
    public static func branch(
        _ name: String,
        sha: String = String(repeating: "a", count: 40),
        upstream: String? = nil,
        type: BranchType = .local
    ) -> Branch {
        Branch(
            name: name,
            upstream: upstream,
            tip: BranchTip(sha: sha),
            type: type,
            ref: type == .local ? "refs/heads/\(name)" : "refs/remotes/\(name)"
        )
    }

    /// A GitHub repository on github.com.
    public static func gitHubRepository(
        owner: String = "octocat",
        name: String = "app",
        dbID: Int = 1,
        endpoint: String = "https://api.github.com",
        permissions: GitHubRepositoryPermission? = .write,
        parent: GitHubRepository? = nil
    ) -> GitHubRepository {
        GitHubRepository(
            name: name,
            owner: Owner(login: owner, endpoint: endpoint, id: dbID),
            dbID: dbID,
            isPrivate: false,
            htmlURL: "https://github.com/\(owner)/\(name)",
            cloneURL: "https://github.com/\(owner)/\(name).git",
            permissions: permissions,
            parent: parent
        )
    }

    /// A changed file, fully included or excluded.
    public static func file(
        _ path: String,
        status: AppFileStatus = .modified(),
        included: Bool = true
    ) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(
            path: path,
            status: status,
            selection: DiffSelection.fromInitialSelection(included ? .all : .none)
        )
    }
}
