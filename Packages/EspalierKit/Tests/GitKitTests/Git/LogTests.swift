// Ported from desktop/app/test/unit/git/log-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/log")
struct LogTests {
    @Suite("getCommits")
    struct GetCommits {
        @Test("loads history")
        func loadsHistory() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo-with-tags")
            let repository = Repository(path: testRepoPath)

            let commits = try await getCommits(repository, "HEAD", limit: 100)
            #expect(commits.count == 5)

            let firstCommit = try #require(commits.last)
            #expect(firstCommit.summary == "first")
            #expect(firstCommit.sha == "7cd6640e5b6ca8dbfd0b33d0281ebe702127079c")
            #expect(firstCommit.shortSha == "7cd6640")
        }

        @Test("handles repository with HEAD file on disk")
        func handlesHEADFileOnDisk() async throws {
            let path = try setupFixtureRepository("repository-with-HEAD-file")
            let repo = Repository(path: path)
            let commits = try await getCommits(repo, "HEAD", limit: 100)
            #expect(commits.count == 2)
        }

        @Test("handles repository with signed commit and log.showSignature set")
        func handlesSignedCommitWithShowSignature() async throws {
            let path = try setupFixtureRepository("just-doing-some-signing")
            let repository = Repository(path: path)

            // ensure the default config is to try and show signatures
            // this should be overriden by the `getCommits` function as it may not
            // have a valid GPG agent configured
            try await setupLocalConfig(repository, [("log.showSignature", "true")])

            let commits = try await getCommits(repository, "HEAD", limit: 100)

            #expect(commits.count == 1)
            #expect(commits[0].sha == "415e4987158c49c383ce7114e0ef00ebf4b070c1")
            #expect(commits[0].shortSha == "415e498")
        }

        @Test("parses tags")
        func parsesTags() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo-with-tags")
            let repository = Repository(path: testRepoPath)

            let commits = try await getCommits(repository, "HEAD", limit: 100)
            #expect(commits.count == 5)

            #expect(commits[0].tags == ["important"])
            #expect(commits[1].tags == ["tentative", "less-important"])
            #expect(commits[2].tags.isEmpty)
        }
    }

    /// `getCommits(_:revisions:...)`, which reads its revisions from standard
    /// input.
    @Suite("getCommits from revisions")
    struct GetCommitsFromRevisions {
        /// `main` (first, second) and `feature` (first, feature), with an
        /// annotated tag on `second`, a lightweight tag on a tree, and a
        /// nested tag on `first`.
        private func makeRepository() async throws -> (Repository, [String: String]) {
            let repository = try setupEmptyRepository("main")
            func run(_ args: [String]) async throws -> String {
                let result = try await Dugite.exec(args, repository.path)
                try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
                return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "1\n")], commitMessage: "first"))
            let first = try await run(["rev-parse", "HEAD"])
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "2\n")], commitMessage: "second"))
            let second = try await run(["rev-parse", "HEAD"])
            try await createBranch(repository, "feature", first)
            try await switchTo(repository, "feature")
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "b.txt", contents: "b\n")], commitMessage: "feature"))
            let feature = try await run(["rev-parse", "HEAD"])
            _ = try await run(["tag", "-a", "-m", "release", "release", second])
            _ = try await run(["tag", "tree", "\(second)^{tree}"])
            _ = try await run(["tag", "-a", "-m", "inner", "inner", first])
            _ = try await run(["tag", "-a", "-m", "outer", "outer", "inner"])
            return (repository, [
                "first": first, "second": second, "feature": feature,
                "release": try await run(["rev-parse", "release"]),
                "tree": try await run(["rev-parse", "tree"]),
                "outer": try await run(["rev-parse", "outer"]),
            ])
        }

        @Test("loads the commits of every revision once, peeling tags and ignoring trees")
        func loadsEveryRevision() async throws {
            let (repository, shas) = try await makeRepository()
            let commits = try await getCommits(
                repository,
                revisions: [shas["feature"]!, shas["release"]!, shas["tree"]!, shas["outer"]!, shas["second"]!],
                additionalArgs: ["--topo-order"]
            )

            #expect(Set(commits.map(\.sha)) == [shas["first"]!, shas["second"]!, shas["feature"]!])
            #expect(commits.count == 3)
            #expect(commits.last?.sha == shas["first"])
            #expect(commits.first { $0.sha == shas["second"] }?.tags == ["release"])
        }

        @Test("pages with limit and skip")
        func pages() async throws {
            let (repository, shas) = try await makeRepository()
            let revisions = [shas["feature"]!, shas["second"]!]
            let all = try await getCommits(repository, revisions: revisions, additionalArgs: ["--topo-order"])
            let firstPage = try await getCommits(repository, revisions: revisions, limit: 2, skip: 0, additionalArgs: ["--topo-order"])
            let secondPage = try await getCommits(repository, revisions: revisions, limit: 2, skip: 2, additionalArgs: ["--topo-order"])

            #expect(all.count == 3)
            #expect(firstPage.map(\.sha) == Array(all.prefix(2)).map(\.sha))
            #expect(secondPage.map(\.sha) == [all[2].sha])
        }

        @Test("no revisions is no history, not HEAD's")
        func noRevisions() async throws {
            let (repository, _) = try await makeRepository()
            #expect(try await getCommits(repository, revisions: []).isEmpty)
        }

        @Test("a revision that names no object throws")
        func missingObject() async throws {
            let (repository, shas) = try await makeRepository()
            await #expect(throws: GitError.self) {
                try await getCommits(repository, revisions: [shas["feature"]!, String(repeating: "1", count: 40)])
            }
            // Unless git is told to ignore it.
            let commits = try await getCommits(
                repository,
                revisions: [shas["feature"]!, String(repeating: "1", count: 40)],
                additionalArgs: ["--ignore-missing"]
            )
            #expect(commits.map(\.summary) == ["feature", "first"])
        }
    }

    @Suite("getChangedFiles")
    struct GetChangedFiles {
        @Test("loads the files changed in the commit")
        func loadsChangedFiles() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo-with-tags")
            let repository = Repository(path: testRepoPath)

            let changesetData = try await getChangedFiles(repository, "7cd6640e5b6ca8dbfd0b33d0281ebe702127079c")
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == "README.md")
            #expect(changesetData.files[0].status.kind == .new)
        }

        @Test("detects renames")
        func detectsRenames() async throws {
            let testRepoPath = try setupFixtureRepository("rename-history-detection")
            let repository = Repository(path: testRepoPath)

            let first = try await getChangedFiles(repository, "55bdecb")
            #expect(first.files.count == 1)

            #expect(first.files[0].path == "NEWER.md")
            #expect(first.files[0].status == .renamed(
                oldPath: "NEW.md",
                renameIncludesModifications: true,
                submoduleStatus: nil
            ))

            let second = try await getChangedFiles(repository, "c898ca8")
            #expect(second.files.count == 1)

            #expect(second.files[0].path == "NEW.md")
            #expect(second.files[0].status == .renamed(
                oldPath: "OLD.md",
                renameIncludesModifications: false,
                submoduleStatus: nil
            ))
        }

        @Test("detect copies")
        func detectCopies() async throws {
            let testRepoPath = try setupFixtureRepository("copies-history-detection")
            let repository = Repository(path: testRepoPath)

            // ensure the test repository is configured to detect copies
            try await setupLocalConfig(repository, [("diff.renames", "copies")])

            let changesetData = try await getChangedFiles(repository, "a500bf415")
            #expect(changesetData.files.count == 2)

            #expect(changesetData.files[0].path == "duplicate-with-edits.md")
            #expect(changesetData.files[0].status == .copied(
                oldPath: "initial.md",
                renameIncludesModifications: false,
                submoduleStatus: nil
            ))

            #expect(changesetData.files[1].path == "duplicate.md")
            #expect(changesetData.files[1].status == .copied(
                oldPath: "initial.md",
                renameIncludesModifications: false,
                submoduleStatus: nil
            ))
        }

        // History shows each file's counts.
        @Test("keeps each file's lines added and deleted, and none for a binary file")
        func keepsLineCounts() async throws {
            let repository = try setupEmptyRepository()
            try await makeCommit(repository, Tree(entries: [
                TreeEntry(path: "a.txt", contents: "one\ntwo\nthree\n"),
                TreeEntry(path: "b.txt", contents: "gone\n"),
            ]))
            try await makeCommit(repository, Tree(entries: [
                TreeEntry(path: "a.txt", contents: "one\n2\nthree\nfour\n"),
                TreeEntry(path: "b.txt", contents: nil),
                TreeEntry(path: "image.bin", contents: Data([0, 1, 2, 0, 255])),
            ]))

            let changesetData = try await getChangedFiles(repository, "HEAD")
            func counts(_ path: String) -> FileLineCount? {
                changesetData.files.first { $0.path == path }.flatMap { changesetData.lineCounts[$0.id] }
            }
            #expect(counts("a.txt") == FileLineCount(added: 2, deleted: 1))
            #expect(counts("b.txt") == FileLineCount(added: 0, deleted: 1))
            #expect(counts("image.bin") == FileLineCount(added: nil, deleted: nil))
            // The totals are the files' sums, binary files counting none.
            #expect(changesetData.linesAdded == 2)
            #expect(changesetData.linesDeleted == 2)
        }

        @Test("handles commit when HEAD exists on disk")
        func handlesCommitWhenHEADExistsOnDisk() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo-with-tags")
            let repository = Repository(path: testRepoPath)

            let changesetData = try await getChangedFiles(repository, "HEAD")
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == "README.md")
            #expect(changesetData.files[0].status.kind == .modified)
        }
    }

    @Test("detects submodule changes within commits")
    func detectsSubmoduleChanges() async throws {
        let repoPath = try setupFixtureRepository("submodule-basic-setup")
        let repository = Repository(path: repoPath)

        let changesetData = try await getChangedFiles(repository, "HEAD")
        #expect(changesetData.files.count == 2)
        #expect(changesetData.files[1].path == "foo/submodule")
        #expect(changesetData.files[1].status.submoduleStatus != nil)
    }
}
