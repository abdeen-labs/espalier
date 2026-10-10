// What Publish loads before publishing: the description and the account's
// organizations. Publishing itself is PublishOperations.swift.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

extension SyncModel {
    /// The organizations `account` belongs to, which a repository can be
    /// published to, sorted by login ignoring case. Empty when there are none
    /// or they can't be loaded.
    public func publishOrganizations(for account: Account) async -> [APIOrganization] {
        guard let repository else {
            return []
        }
        let environment = repository.environment
        let organizations = await environment.withRuntimes {
            await API.fromAccount(account, runtime: environment.gitHub).fetchOrgs()
        }
        return stableSorted(organizations) { JSCompat.caseInsensitiveCompare($0.login, $1.login) }
    }

    /// The description Publish starts with: the repository's
    /// `.git/description`, unless it's git's placeholder.
    public func publishDescription() async -> String {
        guard let repository else {
            return ""
        }
        return await getGitDescription(repository.record.path)
    }
}
