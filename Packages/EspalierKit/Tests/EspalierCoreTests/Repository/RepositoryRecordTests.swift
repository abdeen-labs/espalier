// Ported from desktop/app/test/unit/repository-test.ts
// Plus tests of the record and its helpers.

@testable import EspalierCore
import Foundation
import GitHubKit
import GitKit
import TestSupport
import Testing

@Suite("Repository")
struct RepositoryRecordTests {
    @Suite("name")
    struct Name {
        @Test("uses the last path component as the name")
        func lastPathComponent() {
            let repository = RepositoryRecord(path: "/some/cool/path")
            #expect(repository.name == "path")
        }

        @Test("handles repository at root of the drive")
        func rootOfDrive() {
            #expect(RepositoryRecord(path: "/").name == "/")
        }

        @Test("prefers the GitHub repository's name, unless it is empty")
        func gitHubName() {
            var repository = RepositoryRecord(path: "/src/local-name")
            repository.gitHubRepository = gitHubRepoFixture(owner: "octocat", name: "Hello-World")
            #expect(repository.name == "Hello-World")

            repository.gitHubRepository = gitHubRepoFixture(owner: "octocat", name: "")
            #expect(repository.name == "local-name")
        }

        @Test("shows the alias in place of the name")
        func displayName() {
            var repository = RepositoryRecord(path: "/src/app")
            #expect(repository.displayName == "app")
            repository.alias = "Work app"
            #expect(repository.displayName == "Work app")
            #expect(repository.name == "app")
        }
    }

    @Test("resolves the git directory and builds GitKit's repository")
    func gitRepository() {
        let plain = RepositoryRecord(path: "/src/app")
        #expect(plain.resolvedGitDir == "/src/app/.git")
        #expect(plain.gitRepository.path == "/src/app")
        #expect(plain.gitRepository.gitDir == nil)

        let worktree = RepositoryRecord(path: "/src/app-feature", gitDir: "/src/app/.git/worktrees/app-feature")
        #expect(worktree.resolvedGitDir == "/src/app/.git/worktrees/app-feature")
        #expect(worktree.gitRepository.gitDir == "/src/app/.git/worktrees/app-feature")
    }

    @Suite("GitHub helpers")
    struct GitHubHelpers {
        let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")

        var fork: GitHubRepository {
            gitHubRepoFixture(owner: "contributor", name: "desktop", parent: parent)
        }

        @Test("a repository without a GitHub repository")
        func plain() {
            let repository = RepositoryRecord(path: "/src/app")
            #expect(!isRepositoryWithGitHubRepository(repository))
            #expect(!isRepositoryWithForkedGitHubRepository(repository))
            #expect(getNonForkGitHubRepository(repository) == nil)
            #expect(getGitHubHtmlUrl(repository) == nil)
            #expect(nameOf(repository) == "app")
            #expect(getForkContributionTarget(repository) == .parent)
            #expect(!isForkedRepositoryContributingToParent(repository))
        }

        @Test("a repository on GitHub that isn't a fork")
        func notAFork() {
            let repository = RepositoryRecord(path: "/src/desktop", gitHubRepository: parent)
            #expect(isRepositoryWithGitHubRepository(repository))
            #expect(!isRepositoryWithForkedGitHubRepository(repository))
            #expect(getNonForkGitHubRepository(repository) == parent)
            #expect(getGitHubHtmlUrl(repository) == "https://github.com/desktop/desktop")
            #expect(nameOf(repository) == "desktop/desktop")
            #expect(!isForkedRepositoryContributingToParent(repository))
        }

        @Test("a fork contributes to its parent unless the user chose the fork")
        func forkContributionTarget() {
            // One fixture: each `fork` has new IDs.
            let fork = self.fork
            var repository = RepositoryRecord(path: "/src/desktop", gitHubRepository: fork)
            #expect(isRepositoryWithForkedGitHubRepository(repository))
            #expect(getForkContributionTarget(repository) == .parent)
            #expect(isForkedRepositoryContributingToParent(repository))
            #expect(getNonForkGitHubRepository(repository) == parent)
            #expect(getGitHubHtmlUrl(repository) == "https://github.com/desktop/desktop")
            #expect(nameOf(repository) == "contributor/desktop")

            repository.workflowPreferences.forkContributionTarget = .fork
            #expect(getForkContributionTarget(repository) == .fork)
            #expect(!isForkedRepositoryContributingToParent(repository))
            #expect(getNonForkGitHubRepository(repository) == fork)
            #expect(getGitHubHtmlUrl(repository) == "https://github.com/contributor/desktop")

            repository.workflowPreferences.forkContributionTarget = .parent
            #expect(isForkedRepositoryContributingToParent(repository))
        }
    }

    @Test("workflow preferences with an unknown target read as no choice")
    func unknownForkContributionTarget() throws {
        let json = #"{"forkContributionTarget":"sideways"}"#
        let preferences = try JSONDecoder().decode(WorkflowPreferences.self, from: Data(json.utf8))
        #expect(preferences.forkContributionTarget == nil)
    }
}
