import Foundation
@testable import GitHubKit
import TestSupport
import Testing

@Suite("models")
struct ModelTests {
    @Suite("GitHubRepository")
    struct GitHubRepositoryTests {
        @Test("is a fork when it has a parent, and round trips through JSON")
        func forksAndCoding() throws {
            let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")
            let fork = gitHubRepoFixture(owner: "octocat", name: "desktop", parent: parent)

            #expect(!parent.fork)
            #expect(fork.fork)
            #expect(fork.parent == parent)
            #expect(fork.fullName == "octocat/desktop")
            #expect(fork.endpoint == "https://api.github.com")

            let decoded = try JSONDecoder().decode(GitHubRepository.self, from: JSONEncoder().encode(fork))
            #expect(decoded == fork)
        }

        @Test("assumes write permission unless it's read-only")
        func writePermission() {
            func repository(_ permissions: GitHubRepositoryPermission?) -> GitHubRepository {
                GitHubRepository(name: "r", owner: Owner(login: "o", endpoint: getDotComAPIEndpoint(), id: 1), dbID: 1, permissions: permissions)
            }

            #expect(hasWritePermission(repository(nil)))
            #expect(hasWritePermission(repository(.write)))
            #expect(hasWritePermission(repository(.admin)))
            #expect(!hasWritePermission(repository(.read)))
        }
    }

    @Suite("avatars")
    struct AvatarTests {
        let repository = gitHubRepoFixture(owner: "desktop", name: "desktop")
        let author = AvatarIdentity(name: "Mona", email: "mona@example.com")

        @Test("lists the author, co-authors, and a different committer once each")
        func listsUsers() {
            let coAuthor = AvatarIdentity(name: "Hubot", email: "hubot@example.com")
            let committer = AvatarIdentity(name: "Lisa", email: "lisa@example.com")

            let users = getAvatarUsersForCommit(repository, author: author, coAuthors: [coAuthor, author], committer: committer)

            #expect(users.map(\.name) == ["Mona", "Hubot", "Lisa"])
            #expect(users.allSatisfy { $0.endpoint == "https://api.github.com" && $0.avatarURL == nil })
        }

        @Test("leaves out a committer who authored or co-authored the commit, or is GitHub's web flow")
        func leavesOutCommitter() {
            let webFlow = AvatarIdentity(name: "GitHub", email: "noreply@github.com")

            #expect(getAvatarUsersForCommit(repository, author: author, coAuthors: [], committer: author).count == 1)
            #expect(getAvatarUsersForCommit(repository, author: author, coAuthors: [], committer: webFlow).count == 1)
            #expect(getAvatarUsersForCommit(nil, author: author, coAuthors: [], committer: webFlow).count == 2)
        }

        @Test("recognizes web flow committers")
        func webFlowCommitters() {
            let enterprise = gitHubRepoFixture(owner: "o", name: "r", endpoint: "https://ghe.io/api/v3")

            #expect(isWebFlowCommitter(AvatarIdentity(name: "GitHub", email: "noreply@github.com"), repository))
            #expect(!isWebFlowCommitter(AvatarIdentity(name: "GitHub", email: "other@github.com"), repository))
            #expect(isWebFlowCommitter(AvatarIdentity(name: "GitHub Enterprise", email: "anything@ghe.io"), enterprise))
            #expect(!isWebFlowCommitter(AvatarIdentity(name: "GitHub Enterprise", email: "x"), repository))
        }

        @Test("shows the Copilot agent's commits as Copilot's")
        func copilotAgentName() {
            let agent = AvatarIdentity(name: "copilot-swe-agent[bot]", email: "198982749+Copilot@users.noreply.github.com")

            let users = getAvatarUsersForCommit(repository, author: agent, coAuthors: [], committer: agent)

            #expect(users.map(\.name) == ["Copilot"])
        }

        @Test("parses stealth emails")
        func parsesStealthEmails() {
            let modern = parseStealthEmail("123+octocat@users.noreply.github.com", getDotComAPIEndpoint())
            #expect(modern?.id == 123)
            #expect(modern?.login == "octocat")

            let legacy = parseStealthEmail("octocat@users.noreply.github.com", getDotComAPIEndpoint())
            #expect(legacy?.id == nil)
            #expect(legacy?.login == "octocat")

            #expect(parseStealthEmail("octocat@example.com", getDotComAPIEndpoint()) == nil)
            #expect(parseStealthEmail("octocat@users.noreply.github.com", "https://ghe.io/api/v3") == nil)
            #expect(parseStealthEmail("1+monalisa@users.noreply.ghe.io", "https://ghe.io/api/v3")?.login == "monalisa")
        }
    }

    @Suite("repo rules")
    struct RepoRulesTests {
        @Test("reports failed and bypassable rules")
        func failures() {
            var rules = RepoRulesMetadataRules()
            #expect(!rules.hasRules)
            rules.push(nil)
            rules.push(RepoRulesMetadataRule(enforced: true, matcher: { $0.hasPrefix("feat") }, humanDescription: "must start with \"feat\"", rulesetId: 1))
            rules.push(RepoRulesMetadataRule(enforced: .bypass, matcher: { $0.count < 10 }, humanDescription: "must be short", rulesetId: 2))

            #expect(rules.hasRules)
            #expect(rules.getRules().count == 2)
            #expect(rules.getFailedRules("feat: x").status == .pass)
            #expect(rules.getFailedRules("feat: a long one").status == .bypass)
            let failed = rules.getFailedRules("fix")
            #expect(failed.status == .fail)
            #expect(failed.failed == [RepoRulesMetadataFailure(description: "must start with \"feat\"", rulesetId: 1)])
        }
    }

    @Suite("accounts")
    struct AccountTests {
        @Test("describes accounts")
        func describesAccounts() {
            let dotCom = Account(login: "octocat", endpoint: getDotComAPIEndpoint(), token: "t", emails: [], avatarURL: "", id: 1, name: "")
            let enterprise = Account(login: "mona", endpoint: "https://GHE.example.com/api/v3", token: "t", emails: [], avatarURL: "", id: 2, name: "Mona")

            #expect(dotCom.friendlyName == "octocat")
            #expect(enterprise.friendlyName == "Mona")
            #expect(dotCom.friendlyEndpoint == "GitHub.com")
            #expect(enterprise.friendlyEndpoint == "ghe.example.com")
            #expect(isDotComAccount(dotCom) && isEnterpriseAccount(enterprise))
            #expect(accountEquals(dotCom, dotCom.withToken("")))
            #expect(Account.anonymous().id == -1)
            #expect(dotCom.gitAccount == GitAccount(login: "octocat", endpoint: getDotComAPIEndpoint(), token: "t"))
        }
    }
}
