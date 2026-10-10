// Git LFS end to end through the models, with the bundled git-lfs: pointer
// files in the Changes and History diffs, a checkout that downloads LFS
// files from a local remote with Git LFS's progress, a repository whose LFS
// filters aren't installed, and a file over GitHub's size limit.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Edge states: Git LFS", .offline, .hangGuard(minutes: 5)) @MainActor
struct LFSStateTests {
    /// A repository on `main` with Git LFS installed locally, tracking
    /// `*.bin`, and `asset.bin` committed.
    private func makeRepository() async throws -> Repository {
        let local = try setupEmptyRepositoryDefaultMain()
        try await runGit(["lfs", "install", "--local"], local)
        try await runGit(["lfs", "track", "*.bin"], local)
        try Data("first version\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "asset.bin")))
        try await runGit(["add", ".gitattributes", "asset.bin"], local)
        try await runGit(["commit", "-q", "-m", "Add asset"], local)
        return local
    }

    @Test("an LFS file's diff is its pointer, in Changes and in History; the working file has its content")
    func pointerDiffs() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await makeRepository()
            let fixture = try await ChangesFixture.make(local)
            #expect(fixture.read("asset.bin") == "first version\n")
            #expect(try await fixture.git(["cat-file", "-p", "HEAD:asset.bin"]).hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            try fixture.write("asset.bin", "second version\n")
            await fixture.refresh()
            try await fixture.select("asset.bin")
            let changed = try fixture.shownText()
            #expect(deletedLines(changed).contains { $0.hasPrefix("oid sha256:") })
            #expect(addedLines(changed).contains { $0.hasPrefix("oid sha256:") })
            #expect(addedLines(changed).contains("size 15"))

            let commit = try await fixture.commitIncluded("Second version")
            #expect(try await fixture.git(["cat-file", "-p", "HEAD:asset.bin"]).contains("size 15"))
            await fixture.activateHistory()
            fixture.history.select(shas: [commit.sha], contiguous: true)
            await fixture.settleHistory()
            let file = try #require(fixture.history.selection.changeset.value?.files.first { $0.path == "asset.bin" })
            fixture.history.selectFile(file)
            await fixture.settleHistory()
            let historyDiff = try #require(textDiffData(fixture.history.selection.diff.value))
            #expect(addedLines(historyDiff).contains("size 15"))
        }
    }

    @Test("checking out a branch downloads its LFS files from the remote, with Git LFS's progress")
    func checkoutDownloads() async throws {
        try await withIsolatedGitConfig { _ in
            // Global filters, as the app installs at launch.
            try await runGit(["lfs", "install"], try setupEmptyRepositoryDefaultMain())
            let seed = try await makeRepository()
            let remote = try await makeBareRemote(from: seed)
            try await runGit(["remote", "add", "origin", remote.path], seed)
            try await runGit(["lfs", "push", "--all", "origin"], seed)

            // Another clone pushes a branch with a new LFS file.
            let other = try await cloneRepository(remote)
            try await runGit(["checkout", "-q", "-b", "feature"], other)
            try Data(String(repeating: "feature asset\n", count: 4_096).utf8).write(to: URL(filePath: POSIXPath.join(other.path, "feature.bin")))
            try await runGit(["add", "feature.bin"], other)
            try await runGit(["commit", "-q", "-m", "Add feature asset"], other)
            try await runGit(["push", "-q", "origin", "feature"], other)

            let local = try await cloneRepository(remote)
            #expect(try String(contentsOfFile: POSIXPath.join(local.path, "asset.bin"), encoding: .utf8) == "first version\n")
            try await runGit(["fetch", "-q", "origin"], local)
            let feature = try #require(try await getBranches(local, "refs/remotes/origin/feature").first)

            let progress = Mutex<[CheckoutProgress]>([])
            _ = try await checkoutBranch(local, feature, nil) { update in
                progress.withLock { $0.append(update) }
            }
            #expect(try String(contentsOfFile: POSIXPath.join(local.path, "feature.bin"), encoding: .utf8).hasPrefix("feature asset\n"))
            let descriptions = progress.withLock { $0 }.compactMap(\.description)
            #expect(descriptions.contains { $0.contains("feature.bin") }, "\(descriptions)")

            // And through the models, back to main and to feature again.
            let fixture = try await ChangesFixture.make(local)
            #expect(fixture.paths.isEmpty)
            #expect(try await fixture.model.branches.checkout(try fixture.branch("main")) != .alreadyCheckedOut)
            await fixture.settle()
            #expect(!fixture.exists("feature.bin"))
            #expect(try await fixture.model.branches.checkout(try fixture.branch("feature")) != .alreadyCheckedOut)
            await fixture.settle()
            #expect(fixture.read("feature.bin")?.hasPrefix("feature asset\n") == true)
            #expect(fixture.paths.isEmpty)
        }
    }

    @Test("without LFS filters, tracked files are their pointers and nothing shows as changed")
    func filtersNotInstalled() async throws {
        try await withIsolatedGitConfig { _ in
            let seed = try await makeRepository()
            let remote = try await makeBareRemote(from: seed)
            // No global filters, so the clone checks out the pointers.
            let local = try await cloneRepository(remote)
            let pointer = try String(contentsOfFile: POSIXPath.join(local.path, "asset.bin"), encoding: .utf8)
            #expect(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            let fixture = try await ChangesFixture.make(local, responder: PromptResponder.dismissing)
            #expect(fixture.paths.isEmpty)
            #expect(fixture.gitState.tip.branch?.name == "main")
        }
    }

    @Test("a 101 MB file Git LFS tracks commits as a pointer without asking; one it doesn't track asks first")
    func overSizeLimit() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await makeRepository()
            let fixture = try await ChangesFixture.make(local)
            for name in ["big.bin", "big.dat"] {
                let path = POSIXPath.join(local.path, name)
                #expect(FileManager.default.createFile(atPath: path, contents: nil))
                let handle = try FileHandle(forWritingTo: URL(filePath: path))
                try handle.truncate(atOffset: UInt64(101 * 1024 * 1024))
                try handle.close()
            }
            await fixture.refresh()

            try fixture.include(["big.dat"])
            fixture.commit.draft.summary = "Big data"
            let error = await #expect(throws: OperationError.self) {
                try await fixture.commit.commit()
            }
            #expect(confirmationKind(of: error) == .commitOversizedFiles)

            try fixture.include(["big.bin"])
            _ = try await fixture.commitIncluded("Big asset")
            #expect(fixture.paths == ["big.dat"])
            let size = try await fixture.git(["cat-file", "-s", "HEAD:big.bin"])
            #expect((Int(JSCompat.trim(size)) ?? .max) < 200)
        }
    }
}
