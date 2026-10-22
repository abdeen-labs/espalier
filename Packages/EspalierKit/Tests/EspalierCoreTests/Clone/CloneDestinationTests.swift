// The clone dialog's behavior that isn't layout: `validateClonePath`, the
// .app warning, the local path that follows the URL, the default folder, and
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

    @Test("a path that isn't a full path can't be cloned into")
    func notFullPath() async {
        #expect(await validateClonePath("Developer/app") == .notFullPath)
        #expect(await validateClonePath("~/Developer/app") == .notFullPath)
        #expect(await validateClonePath("") == .notFullPath)
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

    @Test("a folder whose name ends in .app gets a warning but can be cloned into, whatever the case or trailing separators")
    func applicationBundleCases() async throws {
        let directory = try createTempDirectory()
        for name in ["repository.app", "repository.APP/", ".app", "repository.app/."] {
            let path = "\(directory)/\(name)"
            #expect(clonePathWarning(path) == .applicationBundle, "\(name)")
            #expect(await validateClonePath(path) == nil, "\(name)")
        }
        #expect(clonePathWarning(POSIXPath.join(directory, "repository.app-source")) == nil)
        #expect(clonePathWarning(POSIXPath.join(directory, "repository-app")) == nil)
        // An empty folder that's there can be cloned into; one with files
        // still can't.
        let existing = POSIXPath.join(directory, "existing.app")
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: false)
        #expect(clonePathWarning(existing) == .applicationBundle)
        #expect(await validateClonePath(existing) == nil)
        try Data().write(to: URL(filePath: POSIXPath.join(existing, "file")))
        #expect(await validateClonePath(existing) == .notEmpty)
    }

    @Test("desktop's dialog test: a repository whose name ends in .app gets a folder ending in -app, as derived from the URL or after editing it")
    func applicationBundleFolderName() {
        let directory = "/Users/me/Developer"
        for (url, name) in [
            ("https://github.com/owner/repository.app", "repository-app"),
            ("https://github.com/owner/repository.APP.git", "repository-APP"),
            ("https://github.com/owner/repository.App.git/", "repository-App"),
            ("owner/.app", "-app"),
        ] {
            let path = clonePath(directory, afterURLChangeFrom: "", to: url)
            #expect(path == POSIXPath.join(directory, name), "\(url)")
            #expect(clonePathWarning(path) == nil, "\(url)")
        }
        #expect(cloneFolderName("owner/repository.app-source") == "repository.app-source")
        // Derived after editing the URL, then corrected.
        let changed = clonePath(
            POSIXPath.join(directory, "repository"),
            afterURLChangeFrom: "https://example.com/owner/repository.git",
            to: "https://example.com/owner/changed.app.git"
        )
        #expect(changed == POSIXPath.join(directory, "changed-app"))
        let corrected = clonePath(changed, afterURLChangeFrom: "https://example.com/owner/changed.app.git", to: "https://example.com/owner/changed.git")
        #expect(corrected == POSIXPath.join(directory, "changed"))
    }

    @Test("a clone into a folder whose name ends in .app goes ahead") @MainActor
    func clonesIntoApplicationBundleName() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let source = try await makeCloneSource()
        let destination = POSIXPath.join(try createTempDirectory(), "website.app")

        let id = try await app.clones.clone(source.path, to: destination)

        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, ".git")))
        #expect(app.record(id) != nil)
        await app.idle()
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

    @Test("an owner/name GitHub couldn't be asked about (offline, rate limited) is an API error, not \"not found\"", arguments: [
        NamedCase("offline", MockGitHub.Response.networkError(.notConnectedToInternet)),
        NamedCase("rate limited", .json(["message": "API rate limit exceeded for 127.0.0.1."], status: 403)),
    ])
    func lookupFailed(_ testCase: NamedCase<MockGitHub.Response>) async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: testCase.value)
        let app = await harness.loadedAppWithAccounts()

        let error = await #expect(throws: OperationError.self) {
            try await app.clones.resolveCloneInfo("octocat/hello")
        }
        #expect(error?.operation == .clone)
        guard case .api? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        await settle(app, harness)
    }

    @Test("a signed-in account's \"not found\" stands when the anonymous lookup after it fails; an Enterprise server's failure counts", arguments: [
        NamedCase("GitHub.com alone: not found", false),
        NamedCase("an Enterprise server that can't be reached: its failure", true),
    ])
    func notFoundBeforeAnonymousFailure(_ testCase: NamedCase<Bool>) async throws {
        let enterprise = testCase.value
        let harness = try AppHarness()
        harness.mockUser("octocat", id: 1)
        // The account finds nothing, and the anonymous lookup is rate limited.
        harness.gitHub.on("GET", "/repos/octocat/typo") { request in
            request.header("Authorization") == nil
                ? .json(["message": "API rate limit exceeded for 127.0.0.1."], status: 403)
                : .status(404)
        }
        if enterprise {
            try await harness.store(dotComAccount(), enterpriseAccount())
            harness.mockUser("enterprise-user", id: 2, prefix: "/api/v3")
            harness.gitHub.on("GET", "/api/v3/repos/octocat/typo", respond: .networkError(.notConnectedToInternet))
        } else {
            try await harness.store(dotComAccount())
        }
        let app = await harness.loadedAppWithAccounts()

        let error = await #expect(throws: OperationError.self) {
            try await app.clones.resolveCloneInfo("octocat/typo")
        }
        #expect(harness.gitHub.requests("GET", "/repos/octocat/typo").map { $0.header("Authorization") == nil } == [false, true])
        if enterprise {
            guard case .api(let failure)? = error?.reason else {
                Issue.record("Unexpected error \(String(describing: error))")
                return
            }
            // The Enterprise server's, which had no response.
            #expect(failure.status == nil)
        } else {
            #expect(preconditionText(error) != nil)
        }
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
