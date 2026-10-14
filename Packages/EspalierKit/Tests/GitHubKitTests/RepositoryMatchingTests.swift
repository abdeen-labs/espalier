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

        @Test("matches HTTPS remotes by host and port, SSH remotes by host", arguments: [
            NamedCase("an HTTPS remote on the server's port", (endpoint: "https://ghe.example.com:8443/api/v3", remote: "https://ghe.example.com:8443/someuser/somerepo.git", matches: true)),
            NamedCase("an HTTPS remote on another port", (endpoint: "https://ghe.example.com:8443/api/v3", remote: "https://ghe.example.com/someuser/somerepo.git", matches: false)),
            NamedCase("an HTTPS remote on a port the server isn't on", (endpoint: "https://ghe.example.com/api/v3", remote: "https://ghe.example.com:8443/someuser/somerepo.git", matches: false)),
            NamedCase("an HTTPS remote naming the default port", (endpoint: "https://api.github.com", remote: "https://github.com:443/someuser/somerepo.git", matches: true)),
            NamedCase("an SSH remote of a server on another port", (endpoint: "https://ghe.example.com:8443/api/v3", remote: "git@ghe.example.com:someuser/somerepo.git", matches: true)),
            NamedCase("an SSH remote with a port", (endpoint: "https://ghe.example.com/api/v3", remote: "ssh://git@ghe.example.com:2222/someuser/somerepo.git", matches: true)),
            NamedCase("GitHub's SSH over HTTPS", (endpoint: "https://api.github.com", remote: "ssh://git@ssh.github.com:443/someuser/somerepo.git", matches: true)),
            NamedCase("a host in another case", (endpoint: "https://api.github.com", remote: "https://GitHub.com/someuser/somerepo.git", matches: true)),
            NamedCase("an @ in the path", (endpoint: "https://api.github.com", remote: "https://evil.example/x@github.com/someuser/somerepo.git", matches: false)),
        ])
        func matchesServers(_ testCase: NamedCase<(endpoint: String, remote: String, matches: Bool)>) {
            let repo = matchGitHubRepository([account(endpoint: testCase.value.endpoint)], testCase.value.remote)
            #expect((repo != nil) == testCase.value.matches)
            if let repo {
                #expect(repo.owner == "someuser")
                #expect(repo.name == "somerepo")
            }
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

    @Test("urlMatchesRemote and urlsMatch agree on servers and case", arguments: [
        NamedCase("owner and name in another case", (url: "https://github.com/shiftkey/desktop.git", remote: "https://github.com/ShiftKey/Desktop", matches: true)),
        NamedCase("a host in another case", (url: "https://github.com/shiftkey/desktop.git", remote: "git@GitHub.com:shiftkey/desktop.git", matches: true)),
        NamedCase("GitHub's SSH over HTTPS", (url: "https://github.com/shiftkey/desktop.git", remote: "ssh://git@ssh.github.com:443/shiftkey/desktop.git", matches: true)),
        NamedCase("an HTTPS remote on the same port", (url: "https://ghe.example.com:8443/shiftkey/desktop.git", remote: "https://ghe.example.com:8443/shiftkey/desktop", matches: true)),
        NamedCase("an HTTPS remote on another port", (url: "https://ghe.example.com:8443/shiftkey/desktop.git", remote: "https://ghe.example.com/shiftkey/desktop", matches: false)),
        NamedCase("an SSH remote of a server on another port", (url: "https://ghe.example.com:8443/shiftkey/desktop.git", remote: "ssh://git@ghe.example.com:2222/shiftkey/desktop.git", matches: true)),
        NamedCase("another host", (url: "https://github.com/shiftkey/desktop.git", remote: "https://ghe.example.com/shiftkey/desktop", matches: false)),
    ])
    func urlComparisonsAgree(_ testCase: NamedCase<(url: String, remote: String, matches: Bool)>) {
        #expect(urlMatchesRemote(testCase.value.url, remoteURL: testCase.value.remote) == testCase.value.matches)
        #expect(urlsMatch(testCase.value.url, testCase.value.remote) == testCase.value.matches)
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
