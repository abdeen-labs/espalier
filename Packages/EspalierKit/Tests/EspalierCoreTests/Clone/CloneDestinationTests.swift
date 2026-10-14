// The clone dialog's behavior that isn't layout: `validateClonePath`, the
// local path that follows the URL, the default folder, and
// `resolveCloneInfo` against a mock GitHub. "desktop's dialog test"
// carries over the cases of
// desktop/app/test/unit/ui/clone-repository-test.tsx that aren't about
// its layout.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Clone destination")
struct CloneDestinationTests {
    // MARK: validateClonePath

    @Test("a folder that isn't there yet, or an empty one, can be cloned into")
    func valid() async throws {
        let directory = try createTempDirectory()
        #expect(await validateClonePath(POSIXPath.join(directory, "new")) == nil)
        #expect(await validateClonePath(POSIXPath.join(directory, "new", "deeper")) == nil)
        #expect(await validateClonePath(directory) == nil)
    }

    @Test("a folder with files, even hidden ones, can't be cloned into")
    func notEmpty() async throws {
        let directory = try createTempDirectory()
        try Data().write(to: URL(filePath: POSIXPath.join(directory, ".hidden")))

        #expect(await validateClonePath(directory) == .notEmpty)
    }

    @Test("a file isn't a folder")
    func file() async throws {
        let file = POSIXPath.join(try createTempDirectory(), "file")
        try Data("x".utf8).write(to: URL(filePath: file))

        #expect(await validateClonePath(file) == .notAFolder)
    }

    @Test("desktop's dialog test: .app folders are refused, as derived from the URL or edited, whatever the case or trailing separators")
    func applicationBundleCases() async throws {
        let directory = try createTempDirectory()
        // Derived from the URL, without renaming.
        for (url, name) in [
            ("https://github.com/owner/repository.app", "repository.app"),
            ("https://github.com/owner/repository.APP.git", "repository.APP"),
            ("https://github.com/owner/repository.App.git/", "repository.App"),
        ] {
            let path = clonePath(directory, afterURLChangeFrom: "", to: url)
            #expect(path == POSIXPath.join(directory, name))
            #expect(await validateClonePath(path) == .applicationBundle, "\(url)")
        }
        // Edited.
        for name in ["repository.app", "repository.APP/", ".app", "repository.app/."] {
            #expect(await validateClonePath("\(directory)/\(name)") == .applicationBundle, "\(name)")
        }
        #expect(await validateClonePath(POSIXPath.join(directory, "repository.app-source")) == nil)
        // An empty folder that's there.
        let empty = POSIXPath.join(directory, "empty.app")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: false)
        #expect(await validateClonePath(empty) == .applicationBundle)
        // Derived after editing the URL, then corrected.
        let changed = clonePath(
            POSIXPath.join(directory, "repository"),
            afterURLChangeFrom: "https://example.com/owner/repository.git",
            to: "https://example.com/owner/changed.app.git"
        )
        #expect(changed == POSIXPath.join(directory, "changed.app"))
        #expect(await validateClonePath(changed) == .applicationBundle)
        let corrected = clonePath(changed, afterURLChangeFrom: "https://example.com/owner/changed.app.git", to: "https://example.com/owner/changed.git")
        #expect(corrected == POSIXPath.join(directory, "changed"))
        #expect(await validateClonePath(corrected) == nil)
    }

    @Test("a folder that can't be read is reported")
    func unreadable() async throws {
        let directory = POSIXPath.join(try createTempDirectory(), "locked")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        try #require(chmod(directory, 0) == 0)
        defer { chmod(directory, 0o755) }

        #expect(await validateClonePath(directory) == .unreadable)
    }

    // MARK: The local path

    @Test("the folder name is the repository's, made one safe path component")
    func folderName() {
        #expect(cloneFolderName("https://github.com/desktop/desktop.git") == "desktop")
        #expect(cloneFolderName("git@github.com:desktop/desktop.git") == "desktop")
        #expect(cloneFolderName("desktop/desktop") == "desktop")
        #expect(cloneFolderName("https://example.com/owner/name.git/") == "name")
        #expect(cloneFolderName("https://example.com/owner/..") == nil)
        #expect(cloneFolderName("not a repository") == nil)
        #expect(cloneFolderName("") == nil)
    }

    @Test("the local path follows the URL")
    func pathFollowsURL() {
        let base = "/Users/me/Developer"
        // A first URL adds its name to the folder.
        let first = clonePath(base, afterURLChangeFrom: "", to: "octocat/hello")
        #expect(first == "/Users/me/Developer/hello")
        // Another replaces it.
        let second = clonePath(first, afterURLChangeFrom: "octocat/hello", to: "https://github.com/octocat/world.git")
        #expect(second == "/Users/me/Developer/world")
        // One that names no repository leaves the folder.
        #expect(clonePath(second, afterURLChangeFrom: "https://github.com/octocat/world.git", to: "https://") == base)
        // Without a repository before or after, the path stays.
        #expect(clonePath(base, afterURLChangeFrom: "nothing", to: "still nothing") == base)
        // A folder the user named stays.
        #expect(clonePath("/Volumes/Work/mine", afterURLChangeFrom: "octocat/hello", to: "octocat/other") == "/Volumes/Work/mine")
        #expect(clonePath("/Volumes/Work/mine", afterURLChangeFrom: "octocat/hello", to: "") == "/Volumes/Work/mine")
    }

    @Test("clones go to ~/Developer at first, then the last folder cloned into") @MainActor
    func defaultFolder() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        #expect(app.clones.defaultClonePath(for: "octocat/hello") == POSIXPath.join(harness.root, "Developer", "hello"))
        #expect(app.clones.defaultClonePath(for: "") == POSIXPath.join(harness.root, "Developer"))

        let source = try await makeCloneSource()
        let destination = POSIXPath.join(try createTempDirectory(), "projects", "hello")
        _ = try await app.clones.clone(source.path, to: destination)

        #expect(app.preferences.lastCloneLocation == POSIXPath.dirname(destination))
        #expect(app.clones.defaultClonePath(for: "octocat/world") == POSIXPath.join(POSIXPath.dirname(destination), "world"))
        // Remembered across launches.
        let relaunched = await harness.loadedApp()
        #expect(relaunched.clones.defaultClonePath(for: "octocat/world") == POSIXPath.join(POSIXPath.dirname(destination), "world"))
        await app.idle()
    }
}

@Suite("Clone URL resolution", .offline) @MainActor
struct CloneResolutionTests {
    @Test("owner/name resolves through the signed-in account to the clone URL and default branch")
    func ownerAndName() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        var repository = apiRepository(owner: "octocat", name: "hello")
        repository = createMockAPIRepository(
            cloneURL: repository.cloneURL,
            sshURL: repository.sshURL,
            htmlURL: repository.htmlURL,
            name: "hello",
            owner: repository.owner,
            defaultBranch: "trunk"
        )
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: APIFullRepository(repository: repository)))
        let app = await harness.loadedAppWithAccounts()

        let info = try await app.clones.resolveCloneInfo(" octocat/hello ")
        #expect(info == APIRepositoryCloneInfo(url: "https://github.com/octocat/hello.git", defaultBranch: "trunk"))
        let requests = harness.gitHub.requests("GET", "/repos/octocat/hello")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.header("Authorization") == "Bearer gho_octocat_token" })
        await settle(app, harness)
    }

    @Test("an SSH URL resolves to the SSH clone URL")
    func sshURL() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(owner: "octocat", name: "hello")))
        let app = await harness.loadedAppWithAccounts()

        let info = try await app.clones.resolveCloneInfo("git@github.com:octocat/hello.git")
        #expect(info.url == "git@github.com:octocat/hello.git")
        #expect(info.defaultBranch == "main")
        await settle(app, harness)
    }

    @Test("without signing in, GitHub.com's public repositories resolve anonymously")
    func anonymous() async throws {
        let harness = try AppHarness()
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(owner: "octocat", name: "hello")))
        let app = await harness.loadedAppWithAccounts()

        let info = try await app.clones.resolveCloneInfo("https://github.com/octocat/hello")
        #expect(info.url == "https://github.com/octocat/hello.git")
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").allSatisfy { $0.header("Authorization") == nil })
        await settle(app, harness)
    }

    @Test("a repository the account's API can't find is refused")
    func notFound() async throws {
        let harness = try AppHarness()
        harness.gitHub.on("GET", "/repos/octocat/secret", respond: .status(404))
        let app = await harness.loadedAppWithAccounts()

        let error = await #expect(throws: OperationError.self) {
            try await app.clones.resolveCloneInfo("https://github.com/octocat/secret.git")
        }
        #expect(error?.operation == .clone)
        #expect(preconditionText(error) != nil)

        // An owner/name no account can see isn't cloned as typed: git could
        // only fail at it.
        let alias = await #expect(throws: OperationError.self) {
            try await app.clones.resolveCloneInfo("octocat/secret")
        }
        #expect(preconditionText(alias) == preconditionText(error))
        await settle(app, harness)
    }

    @Test("other hosts, wikis, and API failures clone what was typed")
    func asTyped() async throws {
        let harness = try AppHarness()
        harness.gitHub.on("GET", "/repos/octocat/broken", respond: .status(500))
        let app = await harness.loadedAppWithAccounts()

        #expect(try await app.clones.resolveCloneInfo("https://gitlab.com/group/project.git") == APIRepositoryCloneInfo(url: "https://gitlab.com/group/project.git"))
        #expect(try await app.clones.resolveCloneInfo("https://github.com/octocat/hello.wiki.git") == APIRepositoryCloneInfo(url: "https://github.com/octocat/hello.wiki.git"))
        #expect(try await app.clones.resolveCloneInfo("/Users/me/src/local") == APIRepositoryCloneInfo(url: "/Users/me/src/local"))
        #expect(try await app.clones.resolveCloneInfo("https://github.com/octocat/broken") == APIRepositoryCloneInfo(url: "https://github.com/octocat/broken"))
        #expect(harness.gitHub.requests.filter { $0.path.hasPrefix("/repos/") }.map(\.path) == ["/repos/octocat/broken"])
        await settle(app, harness)
    }
}
