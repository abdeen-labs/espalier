// Ported from desktop/app/test/unit/repositories-list-grouping-test.ts and
// desktop/app/test/unit/repositories-clone-grouping-test.ts, plus the recent
// group, group order, clones, badges, and the app model's list.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Repository list grouping")
struct RepositoryListGroupingTests {
    private func repository(_ path: String, _ gitHubRepository: GitHubRepository? = nil, alias: String? = nil) -> RepositoryListEntry {
        .repository(RepositoryRecord(path: path, alias: alias, gitHubRepository: gitHubRepository))
    }

    private func path(_ item: RepositoryListItem) -> String? {
        if case .repository(let record) = item.repository {
            return record.path
        }
        return nil
    }

    private func owner(_ group: RepositoryListGroupItems) -> String? {
        if case .dotcom(let owner) = group.identifier {
            return owner.login
        }
        return nil
    }

    private func isEnterprise(_ group: RepositoryListGroupItems) -> Bool {
        if case .enterprise = group.identifier { true } else { false }
    }

    @Test("groups repositories by owners/Enterprise/Other")
    func groupsByOwner() {
        let repositories = [
            repository("repo1"),
            repository("repo2", gitHubRepoFixture(owner: "me", name: "my-repo2")),
            repository("repo3", gitHubRepoFixture(owner: "", name: "my-repo3", endpoint: "https://github.big-corp.com/api/v3")),
        ]

        let grouped = groupRepositories(repositories, [:], [])
        #expect(grouped.count == 3)

        #expect(owner(grouped[0]) == "me")
        #expect(grouped[0].items.count == 1)
        #expect(path(grouped[0].items[0]) == "repo2")

        #expect(grouped[1].identifier == .enterprise(host: "github.big-corp.com"))
        #expect(grouped[1].items.count == 1)
        #expect(path(grouped[1].items[0]) == "repo3")

        #expect(grouped[2].identifier == .other)
        #expect(grouped[2].items.count == 1)
        #expect(path(grouped[2].items[0]) == "repo1")
    }

    @Test("sorts repositories alphabetically within each group")
    func sortsWithinGroups() {
        let repoA = repository("a")
        let repoB = repository("b", gitHubRepoFixture(owner: "me", name: "b"))
        let repoC = repository("c")
        let repoD = repository("d", gitHubRepoFixture(owner: "me", name: "d"))
        let repoZ = repository("z")

        let grouped = groupRepositories([repoC, repoB, repoZ, repoD, repoA], [:], [])
        #expect(grouped.count == 2)

        #expect(owner(grouped[0]) == "me")
        #expect(grouped[0].items.map(path) == ["b", "d"])

        #expect(grouped[1].identifier == .other)
        #expect(grouped[1].items.map(path) == ["a", "c", "z"])
    }

    @Test("only disambiguates Enterprise repositories")
    func disambiguatesEnterprise() {
        let repoA = repository("repo", gitHubRepoFixture(owner: "user1", name: "repo"))
        let repoB = repository("repo", gitHubRepoFixture(owner: "user2", name: "repo"))
        let repoC = repository(
            "enterprise-repo",
            gitHubRepoFixture(owner: "business", name: "enterprise-repo", endpoint: "https://ghe.io/api/v3")
        )
        let repoD = repository(
            "enterprise-repo",
            gitHubRepoFixture(owner: "silliness", name: "enterprise-repo", endpoint: "https://ghe.io/api/v3")
        )

        let grouped = groupRepositories([repoA, repoB, repoC, repoD], [:], [])
        #expect(grouped.count == 3)

        #expect(owner(grouped[0]) == "user1")
        #expect(grouped[0].items.count == 1)
        #expect(owner(grouped[1]) == "user2")
        #expect(grouped[1].items.count == 1)
        #expect(isEnterprise(grouped[2]))
        #expect(grouped[2].items.count == 2)

        #expect(grouped[0].items[0].text[0] == "repo")
        #expect(!grouped[0].items[0].needsDisambiguation)
        #expect(grouped[1].items[0].text[0] == "repo")
        #expect(!grouped[1].items[0].needsDisambiguation)
        #expect(grouped[2].items[0].text[0] == "enterprise-repo")
        #expect(grouped[2].items[0].needsDisambiguation)
        #expect(grouped[2].items[1].text[0] == "enterprise-repo")
        #expect(grouped[2].items[1].needsDisambiguation)
    }

    @Test("shows the recent group only with more than seven entries; its repositories stay in their groups")
    func recentGroup() {
        let records = (0..<8).map { RepositoryRecord(path: "/r/repo\($0)") }
        let recents = [records[5].id, records[2].id]
        let entries = records.map(RepositoryListEntry.repository)

        let seven = groupRepositories(Array(entries.prefix(7)), [:], recents)
        #expect(seven.map(\.identifier) == [.other])

        let eight = groupRepositories(entries, [:], recents)
        #expect(eight.map(\.identifier) == [.recent, .other])
        #expect(eight[0].items.map(path) == ["/r/repo2", "/r/repo5"])
        #expect(eight[1].items.count == 8)

        // Clones count toward the threshold but are never recent.
        let clone = CloneTask(url: "https://github.com/o/cloning.git", path: "/r/cloning")
        let withClone = groupRepositories(Array(entries.prefix(7)) + [.clone(clone)], [:], recents)
        #expect(withClone.map(\.identifier) == [.recent, .other])
    }

    @Test("disambiguates a recent repository whose title repeats in any group")
    func recentDisambiguation() {
        var entries = (0..<6).map { repository("/r/unique\($0)") }
        let gitHub = RepositoryRecord(path: "/r/app", gitHubRepository: gitHubRepoFixture(owner: "me", name: "app"))
        let local = RepositoryRecord(path: "/s/app")
        entries += [.repository(gitHub), .repository(local)]

        let grouped = groupRepositories(entries, [:], [gitHub.id])
        #expect(grouped.map(\.identifier).first == .recent)
        let recent = grouped[0].items
        #expect(recent.count == 1)
        #expect(recent[0].needsDisambiguation)
        // Not in the GitHub.com group, nor in Other.
        #expect(grouped.dropFirst().flatMap(\.items).allSatisfy { !$0.needsDisambiguation })
    }

    @Test("orders groups by their keys and items by title, ignoring case")
    func ordering() {
        let entries = [
            repository("/r/x", gitHubRepoFixture(owner: "abe", name: "x")),
            repository("/r/y", gitHubRepoFixture(owner: "Zed", name: "y")),
            repository("/r/b"),
            repository("/r/B2", alias: "beta"),
            repository("/r/A"),
            // An Enterprise server's group keeps its port.
            repository("/r/server", gitHubRepoFixture(owner: "o", name: "server", endpoint: "https://ghe.io:8443/api/v3")),
            repository("/r/cloud", gitHubRepoFixture(owner: "o", name: "cloud", endpoint: "https://api.octo.ghe.com:8443/")),
        ]
        let grouped = groupRepositories(entries, [:], [])
        #expect(grouped.map(\.id) == ["1:dotcom:abe", "1:dotcom:Zed", "2:enterprise:ghe.io:8443", "2:enterprise:octo.ghe.com:8443", "3:other"])
        #expect(grouped[4].items.map(\.text) == [["A", "A"], ["b", "b"], ["beta", "B2"]])
    }

    @Test("puts clones in Other with their URL's name, and badges from the indicators")
    func clonesAndBadges() {
        let record = RepositoryRecord(path: "/r/app")
        let clone = CloneTask(url: "https://github.com/octocat/hello.git", path: "/r/hello")
        let indicator = RepositoryIndicator(aheadBehind: AheadBehind(ahead: 1, behind: 2), changedFilesCount: 3)
        let grouped = groupRepositories([.repository(record), .clone(clone)], [record.id: indicator], [])

        #expect(grouped.map(\.identifier) == [.other])
        let items = grouped[0].items
        #expect(items.map(\.text) == [["app", "app"], ["hello"]])
        #expect(items[0].id == .repository(record.id))
        #expect(items[0].aheadBehind == AheadBehind(ahead: 1, behind: 2))
        #expect(items[0].changedFilesCount == 3)
        #expect(items[1].id == .clone(clone.id))
        #expect(items[1].aheadBehind == nil)
        #expect(items[1].changedFilesCount == 0)
    }

    @Test("keeps items with equal titles in list order")
    func stableOrder() {
        let first = RepositoryRecord(path: "/one/app")
        let second = RepositoryRecord(path: "/two/App")
        let grouped = groupRepositories([.repository(first), .repository(second)], [:], [])
        #expect(grouped[0].items.map(\.id) == [.repository(first.id), .repository(second.id)])
        let reversed = groupRepositories([.repository(second), .repository(first)], [:], [])
        #expect(reversed[0].items.map(\.id) == [.repository(second.id), .repository(first.id)])
    }

    @Test("the app model groups its repositories, clones, indicators, and recents")
    @MainActor
    func appModel() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let records = (0..<8).map { RepositoryRecord(path: "/r/repo\($0)") }
        for record in records {
            app.insertRecord(record)
        }
        app.recentRepositoryIDs = [records[3].id]
        app.setIndicator(RepositoryIndicator(aheadBehind: nil, changedFilesCount: 4), for: records[3].id)
        let clone = CloneTask(url: "https://github.com/o/new.git", path: "/r/new")
        app.clones.clones = [clone]

        let groups = app.repositoryListGroups
        #expect(groups.map(\.identifier) == [.recent, .other])
        #expect(groups[0].items.map(\.id) == [.repository(records[3].id)])
        #expect(groups[0].items[0].changedFilesCount == 4)
        #expect(groups[1].items.count == 9)
        #expect(groups[1].items.contains { $0.id == .clone(clone.id) })
        app.clones.clones = []
        await app.idle()
    }
}

@Suite("Clone list grouping")
struct CloneListGroupingTests {
    private static let shiftkey = APIIdentity(id: 1, login: "shiftkey", avatarURL: "", htmlURL: "", type: .user)
    private static let desktop = APIIdentity(id: 2, login: "desktop", avatarURL: "", htmlURL: "", type: .organization)
    private static let octokit = APIIdentity(id: 3, login: "octokit", avatarURL: "", htmlURL: "", type: .organization)

    private func repository(_ name: String, owner: APIIdentity, isPrivate: Bool = false, fork: Bool = false) -> APIRepository {
        APIRepository(
            cloneURL: "https://github.com/\(owner.login)/\(name).git",
            sshURL: "",
            htmlURL: "https://github.com/\(owner.login)/\(name)",
            name: name,
            owner: owner,
            private: isPrivate,
            fork: fork,
            defaultBranch: "",
            pushedAt: "1995-12-17T03:24:00",
            hasIssues: true,
            archived: false
        )
    }

    @Test("groups repositories by owner")
    func groupsByOwner() {
        let repositories = [
            repository("some-repo", owner: Self.shiftkey, isPrivate: true, fork: true),
            repository("octokit.net", owner: Self.octokit),
            repository("desktop", owner: Self.desktop, isPrivate: true),
        ]

        let grouped = groupRepositories(repositories, login: "shiftkey")
        #expect(grouped.count == 3)

        #expect(grouped[0].identifier == yourRepositoriesIdentifier)
        #expect(grouped[0].items.count == 1)
        #expect(grouped[0].items[0].name == "some-repo")

        #expect(grouped[1].identifier == "desktop")
        #expect(grouped[1].items.count == 1)
        #expect(grouped[1].items[0].name == "desktop")

        #expect(grouped[2].identifier == "octokit")
        #expect(grouped[2].items.count == 1)
        #expect(grouped[2].items[0].name == "octokit.net")
    }

    @Test("orders other owners ignoring case")
    func ownerOrder() {
        let owners = ["Zed", "abe", "Mona"].enumerated().map { offset, login in
            APIIdentity(id: 10 + offset, login: login, avatarURL: "", htmlURL: "", type: .user)
        }
        let grouped = groupRepositories(owners.map { repository("r", owner: $0) }, login: "shiftkey")
        #expect(grouped.map(\.identifier) == ["abe", "Mona", "Zed"])
    }

    @Test("matches the account's login ignoring case, sorts names case-sensitively, and describes each repository")
    func details() {
        let me = APIIdentity(id: 4, login: "Mona", avatarURL: "", htmlURL: "", type: .user)
        let repositories = [
            repository("zeta", owner: me),
            repository("Alpha", owner: me, fork: true),
            repository("beta", owner: me, isPrivate: true, fork: true),
            repository("tool", owner: Self.desktop),
        ]

        let grouped = groupRepositories(repositories, login: "mona")
        #expect(grouped.map(\.identifier) == [yourRepositoriesIdentifier, "desktop"])
        let items = grouped[0].items
        #expect(items.map(\.name) == ["Alpha", "beta", "zeta"])
        #expect(items.map(\.kind) == [.fork, .private, .repository])
        #expect(items[0].text == ["Mona/Alpha"])
        #expect(items[0].id == "https://github.com/Mona/Alpha")
        #expect(items[0].url == "https://github.com/Mona/Alpha.git")
        #expect(items[0].archived == false)
    }
}
