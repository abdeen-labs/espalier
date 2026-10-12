// "Initialize Git LFS" against real repositories and the bundled Git LFS.
// Installing writes the global filters too, so every test isolates the
// global configuration.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Git LFS initialization") @MainActor
struct LFSOperationsTests {
    /// A repository whose attributes track `*.psd` with Git LFS, committed,
    /// without Git LFS's hooks installed.
    private func repositoryUsingLFS() async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [
            TreeEntry(path: ".gitattributes", contents: "*.psd filter=lfs diff=lfs merge=lfs -text\n"),
            TreeEntry(path: "README.md", contents: "hello\n"),
        ]))
        return repository
    }

    private func hook(_ name: String, in repository: Repository) -> String? {
        try? String(contentsOfFile: POSIXPath.join(repository.path, ".git", "hooks", name), encoding: .utf8)
    }

    @Test("adding a repository that uses Git LFS asks, and initializing installs its hooks and the filters")
    func initializes() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            let harness = try AppHarness()
            let app = await harness.loadedApp()

            let result = try await app.addRepositories([repository.path])
            let id = try #require(result.added.first)
            #expect(result.usingLFS == [id])
            #expect(hook("pre-push", in: repository) == nil)

            let prompt = try #require(app.lfsInitializationPrompt(for: result.usingLFS))
            #expect(prompt.repositories == [id])
            #expect(prompt.paths == [repository.path])

            let failures = await app.initializeLFS(in: result.usingLFS)

            #expect(failures.isEmpty)
            for name in ["pre-push", "post-checkout", "post-commit", "post-merge"] {
                #expect(hook(name, in: repository)?.contains("git lfs") == true, "\(name)")
            }
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean -- %f")
            #expect(try await getGlobalConfigValue("filter.lfs.process") == "git-lfs filter-process")
            #expect(app.repository(id)?.localOperation == nil)
            await app.idle()
        }
    }

    @Test("one repository that fails doesn't stop the others")
    func continuesPastFailures() async throws {
        try await withIsolatedGitConfig { _ in
            let gone = try await repositoryUsingLFS()
            let kept = try await repositoryUsingLFS()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let result = try await app.addRepositories([gone.path, kept.path])
            #expect(result.usingLFS.count == 2)
            try FileManager.default.removeItem(atPath: gone.path)
            let removed = RepositoryID()

            let failures = await app.initializeLFS(in: [removed] + result.usingLFS)

            #expect(failures.map(\.repositoryID) == [removed, result.usingLFS[0]])
            #expect(failures.allSatisfy { $0.operation == .installLFSHooks })
            #expect(preconditionText(failures.first) != nil)
            #expect(hook("pre-push", in: kept)?.contains("git lfs") == true)
            await app.idle()
        }
    }

    @Test("the question lists up to ten repositories' paths, and none for more")
    func promptPaths() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let records = (0..<11).map { RepositoryRecord(path: "/Users/me/Developer/repository-\($0)", addedAt: Date()) }
        for record in records {
            app.insertRecord(record)
        }

        let three = try #require(app.lfsInitializationPrompt(for: records.prefix(3).map(\.id)))
        #expect(three.paths == records.prefix(3).map(\.path))

        let ten = try #require(app.lfsInitializationPrompt(for: records.prefix(10).map(\.id)))
        #expect(ten.paths.count == 10)

        let eleven = try #require(app.lfsInitializationPrompt(for: records.map(\.id)))
        #expect(eleven.paths.isEmpty)
        #expect(eleven.repositories == records.map(\.id))

        // Repositories no longer in the list are left out.
        #expect(app.lfsInitializationPrompt(for: [RepositoryID()]) == nil)
        #expect(app.lfsInitializationPrompt(for: [RepositoryID(), records[0].id])?.repositories == [records[0].id])
        await app.idle()
    }
}
