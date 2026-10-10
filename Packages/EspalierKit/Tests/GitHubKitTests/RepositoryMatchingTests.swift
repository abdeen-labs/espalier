// Ported from desktop/app/test/unit/repository-matching-test.ts

@testable import GitHubKit
import TestSupport
import Testing

private func account(endpoint: String) -> Account {
    Account(login: "alovelace", endpoint: endpoint, token: "", emails: [], avatarURL: "", id: 1, name: "", plan: "free")
}

@Suite("repository-matching")
struct RepositoryMatchingTests {
    @Suite("matchGitHubRepository")
    struct MatchGitHubRepository {
        @Test("matches HTTPS URLs")
        func matchesHTTPS() throws {
            let accounts = [account(endpoint: "https://api.github.com")]
            let repo = try #require(matchGitHubRepository(accounts, "https://github.com/someuser/somerepo.git"))
            #expect(repo.name == "somerepo")
            #expect(repo.owner == "someuser")
        }

        @Test("doesn't match if there aren't any users with that endpoint")
        func doesNotMatchOtherEndpoints() {
            let accounts = [account(endpoint: "https://github.babbageinc.com")]
            let repo = matchGitHubRepository(accounts, "https://github.com/someuser/somerepo.git")
            #expect(repo == nil)
        }
    }

    @Suite("urlMatchesRemote")
    struct URLMatchesRemote {
        @Suite("with HTTPS remote")
        struct WithHTTPSRemote {
            let remote = "https://github.com/shiftkey/desktop"
            let remoteWithSuffix = "https://github.com/shiftkey/desktop.git"

            @Test("does not match null")
            func doesNotMatchNull() {
                #expect(!urlMatchesRemote(nil, remoteURL: remoteWithSuffix))
            }

            @Test("matches cloneURL from API with different casing")
            func matchesCloneURLWithDifferentCasing() {
                let cloneURL = "https://GITHUB.COM/SHIFTKEY/DESKTOP.git"
                #expect(urlMatchesRemote(cloneURL, remoteURL: remoteWithSuffix))
            }

            @Test("matches cloneURL from API without suffix")
            func matchesCloneURLWithoutSuffix() {
                let cloneURL = "https://github.com/shiftkey/desktop.git"
                #expect(urlMatchesRemote(cloneURL, remoteURL: remote))
            }
        }

        @Suite("with SSH remote")
        struct WithSSHRemote {
            let remote = "git@github.com:shiftkey/desktop.git"

            @Test("matches cloneURL from API")
            func matchesCloneURL() {
                let cloneURL = "https://github.com/shiftkey/desktop.git"
                #expect(urlMatchesRemote(cloneURL, remoteURL: remote))
            }
        }
    }

    @Suite("cloneUrlMatches")
    struct CloneURLMatches {
        let repository = gitHubRepoFixture(owner: "shiftkey", name: "desktop", isPrivate: false)

        let repositoryWithoutCloneURL = GitHubRepository(
            name: "desktop",
            owner: Owner(login: "shiftkey", endpoint: "https://api.github.com/", id: 1234),
            dbID: 1,
            isPrivate: false,
            htmlURL: "https://github.com/shiftkey/desktop",
            cloneURL: nil,
            issuesEnabled: true,
            isArchived: false,
            permissions: nil,
            parent: nil
        )

        @Test("returns true when URL doesn't have a .git suffix")
        func matchWithoutSuffix() {
            #expect(urlMatchesCloneURL("https://github.com/shiftkey/desktop", repository) == true)
        }

        @Test("returns false when URL belongs to a different owner")
        func differentOwner() {
            #expect(urlMatchesCloneURL("https://github.com/outofambit/desktop.git", repository) == false)
        }

        @Test("returns false if GitHub repository does't have a cloneURL set")
        func noCloneURL() {
            #expect(urlMatchesCloneURL("https://github.com/shiftkey/desktop", repositoryWithoutCloneURL) == false)
        }
    }
}
