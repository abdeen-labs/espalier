// Ported from desktop/app/test/unit/git/tag-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/tag")
struct TagTests {
    @Suite("createTag")
    struct CreateTag {
        @Test("creates a tag", arguments: [
            NamedCase("creates a tag with the a comma in it", "my-new-tag,has-a-comma"),
        ])
        func createsTag(_ testCase: NamedCase<String>) async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createTag(repository, testCase.value, "HEAD")

            let commit = try #require(try await getCommit(repository, "HEAD"))
            #expect(commit.tags == [testCase.value])
        }

        @Test("creates multiple tags")
        func createsMultipleTags() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createTag(repository, "my-new-tag", "HEAD")
            try await createTag(repository, "another-tag", "HEAD")

            let commit = try #require(try await getCommit(repository, "HEAD"))
            #expect(commit.tags == ["my-new-tag", "another-tag"])
        }

        @Test("creates a tag on a specified commit")
        func createsTagOnSpecifiedCommit() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let commits = try await getCommits(repository, "HEAD", limit: 2)
            let commitSha = commits[1].sha

            try await createTag(repository, "my-new-tag", commitSha)

            let commit = try #require(try await getCommit(repository, commitSha))
            #expect(commit.tags == ["my-new-tag"])
        }

        @Test("fails when creating a tag with a name that already exists")
        func failsForExistingName() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createTag(repository, "my-new-tag", "HEAD")

            let error = await #expect(throws: GitError.self) {
                try await createTag(repository, "my-new-tag", "HEAD")
            }
            #expect(error?.message.range(of: "already exists", options: .caseInsensitive) != nil)
        }
    }

    @Suite("deleteTag")
    struct DeleteTag {
        @Test("deletes a tag with the given name")
        func deletesTag() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createTag(repository, "my-new-tag", "HEAD")
            try await deleteTag(repository, "my-new-tag")

            let commit = try await getCommit(repository, "HEAD")
            #expect(commit?.tags.count == 0)
        }
    }

    @Suite("getAllTags")
    struct GetAllTags {
        @Test("returns an empty map when the repository has no tags")
        func emptyWithoutTags() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            #expect(try await getAllTags(repository).isEmpty)
        }

        @Test("returns all the created tags")
        func returnsAllCreatedTags() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let commit = try #require(try await getCommit(repository, "HEAD"))

            try await createTag(repository, "my-new-tag", commit.sha)
            try await createTag(repository, "another-tag", commit.sha)

            #expect(try await getAllTags(repository) == [
                "my-new-tag": commit.sha,
                "another-tag": commit.sha,
            ])
        }
    }

    @Suite("fetchTagsToPush")
    struct FetchTagsToPush {
        struct Setup {
            let repository: Repository
            let originRemote: Remote
            let remoteRepository: Repository
        }

        func setup() async throws -> Setup {
            let path = try setupFixtureRepository("test-repo-with-tags")
            let remoteRepository = Repository(path: path)
            let repository = try await setupLocalForkOfRepository(remoteRepository)

            let remotes = try await getRemotes(repository)
            let originRemote = try forceUnwrap("couldn't find origin remote", findDefaultRemote(remotes))

            return Setup(repository: repository, originRemote: originRemote, remoteRepository: remoteRepository)
        }

        @Test("returns an empty array when there are no tags to get pushed")
        func emptyWhenNoTagsToPush() async throws {
            let s = try await setup()
            #expect(try await fetchTagsToPush(s.repository, s.originRemote, "master").count == 0)
        }

        @Test("returns local tags that haven't been pushed")
        func returnsUnpushedLocalTags() async throws {
            let s = try await setup()
            try await createTag(s.repository, "my-new-tag", "HEAD")

            #expect(try await fetchTagsToPush(s.repository, s.originRemote, "master") == ["my-new-tag"])
        }

        @Test("returns an empty array after pushing the tag")
        func emptyAfterPushingTag() async throws {
            let s = try await setup()
            try await createTag(s.repository, "my-new-tag", "HEAD")

            try await push(s.repository, s.originRemote, "master", nil, ["my-new-tag"])

            #expect(try await fetchTagsToPush(s.repository, s.originRemote, "master") == [])
        }

        @Test("does not return a tag created on a non-pushed branch")
        func ignoresTagOnNonPushedBranch() async throws {
            let s = try await setup()
            // Create a tag on a local branch that's not pushed to the remote.
            let branchName = "new-branch"
            // `noTrack:` picks lib/git's createBranch over TestSupport's.
            try await createBranch(s.repository, branchName, "master", noTrack: false)
            let branch = try #require(
                try await getBranches(s.repository, "refs/heads/\(branchName)").first,
                "Could not create branch \(branchName)"
            )

            try Data("Hi world\n".utf8).write(to: URL(filePath: POSIXPath.join(s.repository.path, "README.md")))
            let status = try await getStatusOrThrow(s.repository)
            let files = status.workingDirectory.files

            try await checkoutBranch(s.repository, branch, nil)
            let commitSha = try await createCommit(s.repository, "a commit", files)
            try await createTag(s.repository, "my-new-tag", commitSha)

            #expect(try await fetchTagsToPush(s.repository, s.originRemote, "master") == [])
        }

        @Test("returns unpushed tags even if it fails to push the branch")
        func returnsUnpushedTagsWhenBranchPushFails() async throws {
            // Create a new commit on the remote repository so the `git push` command
            // that fetchUnpushedTags() does fails.
            let s = try await setup()
            try Data("Hi world\n".utf8).write(to: URL(filePath: POSIXPath.join(s.remoteRepository.path, "README.md")))
            let status = try await getStatusOrThrow(s.remoteRepository)
            let files = status.workingDirectory.files

            try await createCommit(s.remoteRepository, "a commit", files)

            try await createTag(s.repository, "my-new-tag", "HEAD")

            #expect(try await fetchTagsToPush(s.repository, s.originRemote, "master") == ["my-new-tag"])
        }
    }
}
