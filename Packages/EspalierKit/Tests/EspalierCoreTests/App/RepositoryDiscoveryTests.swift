// The scan of a folder for repositories, against real directories: that it
// looks all the way down and inside repositories, what it leaves out, and
// what isn't a repository.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// Makes the directory at `path`, and the ones above it.
private func makeDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// Makes a directory with what a scan takes for a repository, a `.git`
/// directory, at each of `paths` under `root`.
private func makeRepositories(_ paths: [String], in root: String) throws {
    for path in paths {
        try makeDirectory(POSIXPath.join(root, path, ".git"))
    }
}

/// `paths` under `root`.
private func paths(_ paths: [String], in root: String) -> [String] {
    paths.map { POSIXPath.join(root, $0) }
}

@Suite("Repository discovery")
struct RepositoryDiscoveryTests {
    @Test("finds the repositories however far below the folder, in the order of their paths")
    func anyDepth() async throws {
        let root = try createTempDirectory()
        try makeRepositories(["g/h/i/j/k/l", "d/e/f", "b/c", "a"], in: root)
        try makeDirectory(POSIXPath.join(root, "empty/folder"))

        #expect(await RepositoryDiscovery.repositories(in: root) == paths(["a", "b/c", "d/e/f", "g/h/i/j/k/l"], in: root))
    }

    @Test("finds the repositories inside a repository, each after the one it's in")
    func insideRepository() async throws {
        let root = try createTempDirectory()
        try makeRepositories(["other", "app/Packages/tool/deeper/still", "app/Packages/tool", "app", "app/site"], in: root)

        #expect(await RepositoryDiscovery.repositories(in: root) == paths(
            ["app", "app/Packages/tool", "app/Packages/tool/deeper/still", "app/site", "other"],
            in: root
        ))
    }

    @Test("the folder itself counts when it's a repository, with the ones in it")
    func folderIsRepository() async throws {
        let root = try createTempDirectory()
        try makeRepositories([".", "nested"], in: root)
        let expected = [root, POSIXPath.join(root, "nested")]

        #expect(await RepositoryDiscovery.repositories(in: root) == expected)
        // With a trailing separator too, as the same path.
        #expect(await RepositoryDiscovery.repositories(in: root + "/") == expected)
    }

    @Test("leaves out hidden directories, Library, package managers' folders, and bundles, with everything in them")
    func leftOut() async throws {
        let root = try createTempDirectory()
        try makeRepositories([
            ".dotfiles",
            ".config/tool",
            "node_modules/package",
            "web/node_modules/package",
            "Library/Caches/checkout",
            "Tool.app/Contents/checkout",
            // A repository's dependencies, which are repositories inside it.
            "app",
            "app/.build/checkouts/package",
            "app/DerivedData/SourcePackages/checkouts/package",
            "app/build/SourcePackages/checkouts/package",
            // A name with an extension that isn't a bundle's.
            "api.v2/client",
            "web/site",
        ], in: root)

        #expect(await RepositoryDiscovery.repositories(in: root) == paths(["api.v2/client", "app", "web/site"], in: root))
    }

    @Test("doesn't follow symbolic links, except the folder's own")
    func symbolicLinks() async throws {
        let outside = try createTempDirectory()
        try makeRepositories(["target", "group/inner"], in: outside)
        let root = try createTempDirectory()
        try makeRepositories(["real"], in: root)
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(root, "repository-link"), withDestinationPath: POSIXPath.join(outside, "target"))
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(root, "folder-link"), withDestinationPath: outside)
        // A directory whose `.git` is a link to a git directory isn't a
        // repository either, and isn't looked into.
        try makeRepositories(["linked-git/inner"], in: root)
        try FileManager.default.createSymbolicLink(
            atPath: POSIXPath.join(root, "linked-git/.git"),
            withDestinationPath: POSIXPath.join(outside, "target/.git")
        )

        #expect(await RepositoryDiscovery.repositories(in: root) == paths(["real"], in: root))

        // The folder itself may be a link: its repositories are found under
        // the path given.
        let link = POSIXPath.join(try createTempDirectory(), "link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        #expect(await RepositoryDiscovery.repositories(in: link) == paths(["group/inner", "target"], in: link))
    }

    @Test("a linked worktree's folder isn't a repository, and nothing in it is looked at")
    func linkedWorktree() async throws {
        let root = try createTempDirectory()
        let main = Repository(path: POSIXPath.join(root, "main"))
        try FileManager.default.moveItem(atPath: try await setupTwoCommitRepo().path, toPath: main.path)
        let worktree = POSIXPath.join(root, "feature")
        try await runGit(["worktree", "add", "-b", "feature", worktree], main)
        try makeRepositories(["feature/nested"], in: root)

        #expect(await RepositoryDiscovery.repositories(in: root) == [main.path])
        #expect(await RepositoryDiscovery.repositories(in: worktree).isEmpty)
    }

    @Test("leaves out a directory that can't be read")
    func unreadable() async throws {
        let root = try createTempDirectory()
        try makeRepositories(["locked/hidden-away", "open"], in: root)
        let locked = POSIXPath.join(root, "locked")
        try #require(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o755) }

        #expect(await RepositoryDiscovery.repositories(in: root) == paths(["open"], in: root))
        // As the folder to scan, it has no repositories.
        #expect(await RepositoryDiscovery.repositories(in: locked).isEmpty)
    }

    @Test("a folder that isn't there, isn't a directory, or isn't an absolute path has no repositories")
    func noFolder() async throws {
        let root = try createTempDirectory()
        try makeRepositories(["repository"], in: root)
        let file = POSIXPath.join(root, "file")
        try Data("contents".utf8).write(to: URL(filePath: file))

        #expect(await RepositoryDiscovery.repositories(in: POSIXPath.join(root, "missing")).isEmpty)
        #expect(await RepositoryDiscovery.repositories(in: file).isEmpty)
        #expect(await RepositoryDiscovery.repositories(in: "repository").isEmpty)
    }

    @Test("a repository's path keeps the bytes of its name on disk")
    func exactNames() async throws {
        let root = try createTempDirectory()
        // `FileManager` decomposes names, so these are made with `mkdir`.
        let expected = [
            root + "/one/" + Cafe.precomposed,
            root + "/two/" + Cafe.decomposed,
        ]
        for path in expected {
            for directory in [POSIXPath.dirname(path), path, path + "/.git"] where mkdir(directory, 0o700) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        let found = await RepositoryDiscovery.repositories(in: root)
        #expect(found.map(ExactString.init) == expected.map(ExactString.init))
    }

    @Test("stops when its task is cancelled", .hangGuard(minutes: 5))
    func cancellation() async throws {
        let root = try createTempDirectory()
        try makeRepositories(["a", "b"], in: root)

        let scan = Task {
            // Cancelled before the scan starts, so it finds nothing.
            withUnsafeCurrentTask { $0?.cancel() }
            return await RepositoryDiscovery.repositories(in: root)
        }
        #expect(await scan.value.isEmpty)
    }
}
