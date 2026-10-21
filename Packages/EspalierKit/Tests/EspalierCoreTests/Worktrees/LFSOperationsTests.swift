// "Initialize Git LFS" against real repositories and the bundled Git LFS.
// Installing writes the global filters too, so every test isolates the
// global configuration. Hooks of the repositories' own where Git LFS
// installs its own are asked about, and replaced only when the answer says
// so, through the harness's Trash.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A hook of a repository's own.
private let customHook = "#!/bin/sh\nnpm test\n"

@Suite("Git LFS initialization") @MainActor
struct LFSOperationsTests {
    /// Hooks a repository has before it's initialized.
    enum ExistingHooks: Sendable {
        /// Git LFS's, as the bundled Git LFS installs them.
        case installedByGitLFS
        /// A pre-push with this text.
        case prePush(String)
    }

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

    /// The repository's hooks folder, `.git/hooks`.
    private func hooksPath(_ repository: Repository) -> String {
        POSIXPath.join(repository.path, ".git", "hooks")
    }

    /// The path of the repository's `name` hook in `.git/hooks`.
    private func hookPath(_ name: String, in repository: Repository) -> String {
        POSIXPath.join(hooksPath(repository), name)
    }

    private func hook(_ name: String, in repository: Repository) -> String? {
        try? String(contentsOfFile: hookPath(name, in: repository), encoding: .utf8)
    }

    /// Writes `contents` as the repository's `name` hook in `.git/hooks`.
    private func writeHook(_ name: String, _ contents: String, in repository: Repository) throws {
        try FileManager.default.createDirectory(atPath: hooksPath(repository), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: hookPath(name, in: repository)))
    }

    /// Whether `contents` is Git LFS's `name` hook.
    private func isLFSHook(_ contents: String?, _ name: String) -> Bool {
        contents?.contains("git lfs \(name)") == true
    }

    /// What `initializeLFS(in:replacingHooks:)` threw, if anything.
    private func initializeError(_ app: AppModel, _ ids: [RepositoryID], _ answer: LFSHooksAnswer? = nil) async -> OperationError? {
        do throws(OperationError) {
            try await app.initializeLFS(in: ids, replacingHooks: answer)
            return nil
        } catch {
            return error
        }
    }

    /// What `installLFSHooks(replacing:)` threw, if anything.
    private func installError(_ repository: RepositoryModel, replacing: [String]) async -> OperationError? {
        do throws(OperationError) {
            try await repository.installLFSHooks(replacing: replacing)
            return nil
        } catch {
            return error
        }
    }

    /// The hooks a `replaceLFSHooks` decision names.
    private func hooksDecision(_ error: OperationError?) -> [LFSHooksToReplace]? {
        if case .decisionRequired(.replaceLFSHooks(let repositories))? = error?.reason {
            return repositories
        }
        return nil
    }

    /// The text of what the Trash took from `path`.
    private func trashed(_ path: String, in trash: TemporaryTrash) throws -> String? {
        let suffix = "-" + POSIXPath.basename(path)
        let names = try FileManager.default.contentsOfDirectory(atPath: trash.directory)
        guard let name = names.first(where: { $0.hasSuffix(suffix) }) else {
            return nil
        }
        return try String(contentsOfFile: POSIXPath.join(trash.directory, name), encoding: .utf8)
    }

    /// Three repositories that use Git LFS, added to `app`: one without
    /// hooks, one with a pre-push of its own, and one with its own pre-push
    /// and post-merge.
    private func threeRepositories(in app: AppModel) async throws -> (repositories: [Repository], ids: [RepositoryID]) {
        let clean = try await repositoryUsingLFS()
        let prePush = try await repositoryUsingLFS()
        try writeHook("pre-push", customHook, in: prePush)
        let both = try await repositoryUsingLFS()
        try writeHook("pre-push", customHook, in: both)
        try writeHook("post-merge", customHook, in: both)
        let repositories = [clean, prePush, both]
        let result = try await app.addRepositories(repositories.map(\.path))
        #expect(result.usingLFS.count == 3)
        return (repositories, result.usingLFS)
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

            let failures = try await app.initializeLFS(in: result.usingLFS)

            #expect(failures.isEmpty)
            for name in lfsHookNames {
                #expect(isLFSHook(hook(name, in: repository), name), "\(name)")
            }
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean -- %f")
            #expect(try await getGlobalConfigValue("filter.lfs.process") == "git-lfs filter-process")
            #expect(harness.trash.trashedPaths.isEmpty)
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

            let failures = try await app.initializeLFS(in: [removed] + result.usingLFS)

            #expect(failures.map(\.repositoryID) == [removed, result.usingLFS[0]])
            #expect(failures.allSatisfy { $0.operation == .installLFSHooks })
            #expect(preconditionText(failures.first) != nil)
            #expect(isLFSHook(hook("pre-push", in: kept), "pre-push"))
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

    // MARK: Hooks in the way

    @Test("a hook of the repository's own where Git LFS installs one is asked about, and nothing changes")
    func asksAboutHooksInTheWay() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)

            let error = await initializeError(app, [id])

            #expect(hooksDecision(error) == [LFSHooksToReplace(repositoryID: id, path: repository.path, hooks: [hookPath("pre-push", in: repository)])])
            #expect(error?.operation == .installLFSHooks)
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(hook("post-checkout", in: repository) == nil)
            #expect(harness.trash.trashedPaths.isEmpty)
            #expect(app.repository(id)?.localOperation == nil)
            await app.idle()
        }
    }

    @Test("replacing moves the repository's hook to the Trash and installs Git LFS's")
    func replacesHooks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)
            let error = await initializeError(app, [id])
            let decision = try #require(hooksDecision(error))

            let failures = try await app.initializeLFS(in: [id], replacingHooks: LFSHooksAnswer(asked: decision, replace: true))

            #expect(failures.isEmpty)
            let prePush = hookPath("pre-push", in: repository)
            #expect(harness.trash.trashedPaths == [prePush])
            #expect(try trashed(prePush, in: harness.trash) == customHook)
            for name in lfsHookNames {
                #expect(isLFSHook(hook(name, in: repository), name), "\(name)")
            }
            await app.idle()
        }
    }

    @Test("keeping the repository's hook leaves the repository as it was")
    func keepsHooks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)
            let error = await initializeError(app, [id])
            let decision = try #require(hooksDecision(error))

            let failures = try await app.initializeLFS(in: [id], replacingHooks: LFSHooksAnswer(asked: decision, replace: false))

            #expect(failures.isEmpty)
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(hook("post-checkout", in: repository) == nil)
            #expect(harness.trash.trashedPaths.isEmpty)
            await app.idle()
        }
    }

    @Test("Git LFS's own hooks aren't asked about", arguments: [
        NamedCase("Git LFS's hooks", ExistingHooks.installedByGitLFS),
        NamedCase("an earlier Git LFS's pre-push", ExistingHooks.prePush("#!/bin/sh\ngit lfs pre-push \"$@\"\n")),
        NamedCase("an empty pre-push", ExistingHooks.prePush("")),
    ])
    func ownHooksAreNotInTheWay(_ testCase: NamedCase<ExistingHooks>) async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            switch testCase.value {
            case .installedByGitLFS:
                try await GitKit.installLFSHooks(repository, false)
            case .prePush(let contents):
                try writeHook("pre-push", contents, in: repository)
            }
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)

            let failures = try await app.initializeLFS(in: [id])

            #expect(failures.isEmpty)
            for name in lfsHookNames {
                #expect(isLFSHook(hook(name, in: repository), name), "\(name)")
            }
            #expect(harness.trash.trashedPaths.isEmpty)
            await app.idle()
        }
    }

    @Test("with core.hooksPath, the hooks in its folder are asked about and replaced there")
    func hooksPathIsRespected() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try await setConfigValue(repository, "core.hooksPath", ".githooks")
            let githooks = POSIXPath.join(repository.path, ".githooks")
            try FileManager.default.createDirectory(atPath: githooks, withIntermediateDirectories: true)
            let prePush = POSIXPath.join(githooks, "pre-push")
            try Data(customHook.utf8).write(to: URL(filePath: prePush))
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)

            let error = await initializeError(app, [id])
            let decision = try #require(hooksDecision(error))
            #expect(decision == [LFSHooksToReplace(repositoryID: id, path: repository.path, hooks: [prePush])])

            let failures = try await app.initializeLFS(in: [id], replacingHooks: LFSHooksAnswer(asked: decision, replace: true))

            #expect(failures.isEmpty)
            #expect(harness.trash.trashedPaths == [prePush])
            for name in lfsHookNames {
                let contents = try? String(contentsOfFile: POSIXPath.join(githooks, name), encoding: .utf8)
                #expect(isLFSHook(contents, name), "\(name)")
                #expect(hook(name, in: repository) == nil, "\(name)")
            }
            await app.idle()
        }
    }

    @Test("with several repositories, the question names each one's hooks before anything changes, and keeping them initializes the others")
    func severalRepositoriesKeepingHooks() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let (repositories, ids) = try await threeRepositories(in: app)

            let error = await initializeError(app, ids)
            let decision = try #require(hooksDecision(error))
            #expect(decision == [
                LFSHooksToReplace(repositoryID: ids[1], path: repositories[1].path, hooks: [hookPath("pre-push", in: repositories[1])]),
                LFSHooksToReplace(
                    repositoryID: ids[2],
                    path: repositories[2].path,
                    hooks: [hookPath("pre-push", in: repositories[2]), hookPath("post-merge", in: repositories[2])]
                ),
            ])
            #expect(hook("pre-push", in: repositories[0]) == nil)

            let failures = try await app.initializeLFS(in: ids, replacingHooks: LFSHooksAnswer(asked: decision, replace: false))

            #expect(failures.isEmpty)
            for name in lfsHookNames {
                #expect(isLFSHook(hook(name, in: repositories[0]), name), "\(name)")
            }
            #expect(hook("pre-push", in: repositories[1]) == customHook)
            #expect(hook("post-checkout", in: repositories[1]) == nil)
            #expect(hook("pre-push", in: repositories[2]) == customHook)
            #expect(hook("post-merge", in: repositories[2]) == customHook)
            #expect(hook("post-checkout", in: repositories[2]) == nil)
            #expect(harness.trash.trashedPaths.isEmpty)
            await app.idle()
        }
    }

    @Test("with several repositories, replacing moves each one's hooks to the Trash and initializes them all")
    func severalRepositoriesReplacingHooks() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let (repositories, ids) = try await threeRepositories(in: app)
            let error = await initializeError(app, ids)
            let decision = try #require(hooksDecision(error))

            let failures = try await app.initializeLFS(in: ids, replacingHooks: LFSHooksAnswer(asked: decision, replace: true))

            #expect(failures.isEmpty)
            #expect(harness.trash.trashedPaths == [
                hookPath("pre-push", in: repositories[1]),
                hookPath("pre-push", in: repositories[2]),
                hookPath("post-merge", in: repositories[2]),
            ])
            for repository in repositories {
                for name in lfsHookNames {
                    #expect(isLFSHook(hook(name, in: repository), name), "\(name)")
                }
            }
            await app.idle()
        }
    }

    @Test("hooks that changed after the question are asked about again, and nothing moves")
    func asksAgainWhenHooksChange() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)
            let firstError = await initializeError(app, [id])
            let first = try #require(hooksDecision(firstError))
            try writeHook("post-merge", customHook, in: repository)

            let error = await initializeError(app, [id], LFSHooksAnswer(asked: first, replace: true))

            #expect(hooksDecision(error) == [LFSHooksToReplace(
                repositoryID: id,
                path: repository.path,
                hooks: [hookPath("pre-push", in: repository), hookPath("post-merge", in: repository)]
            )])
            #expect(harness.trash.trashedPaths.isEmpty)
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(hook("post-merge", in: repository) == customHook)
            await app.idle()
        }
    }

    @Test("a repository's initialization asks about the hooks it wasn't told to replace, changing nothing")
    func repositoryAsksAboutUnnamedHooks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            try writeHook("post-merge", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(repository, to: app)

            let error = await installError(model, replacing: [hookPath("pre-push", in: repository)])

            #expect(hooksDecision(error) == [LFSHooksToReplace(
                repositoryID: model.id,
                path: repository.path,
                hooks: [hookPath("pre-push", in: repository), hookPath("post-merge", in: repository)]
            )])
            #expect(harness.trash.trashedPaths.isEmpty)
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(hook("post-checkout", in: repository) == nil)
            #expect(model.localOperation == nil)
            await app.idle()
        }
    }

    @Test("replacing a hook that's a link moves the link to the Trash, not the file it points to")
    func replacesLinks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            let fileManager = FileManager.default
            let script = POSIXPath.join(repository.path, "scripts", "pre-push")
            try fileManager.createDirectory(atPath: POSIXPath.join(repository.path, "scripts"), withIntermediateDirectories: true)
            try Data(customHook.utf8).write(to: URL(filePath: script))
            try fileManager.createDirectory(atPath: hooksPath(repository), withIntermediateDirectories: true)
            let prePush = hookPath("pre-push", in: repository)
            try fileManager.createSymbolicLink(atPath: prePush, withDestinationPath: "../../scripts/pre-push")
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)
            let error = await initializeError(app, [id])
            let decision = try #require(hooksDecision(error))
            #expect(decision.first?.hooks == [prePush])

            let failures = try await app.initializeLFS(in: [id], replacingHooks: LFSHooksAnswer(asked: decision, replace: true))

            #expect(failures.isEmpty)
            #expect(harness.trash.trashedPaths == [prePush])
            #expect(try String(contentsOfFile: script, encoding: .utf8) == customHook)
            #expect(try fileManager.attributesOfItem(atPath: prePush)[.type] as? FileAttributeType == .typeRegular)
            #expect(isLFSHook(hook("pre-push", in: repository), "pre-push"))
            await app.idle()
        }
    }

    @Test("a hook that can't be moved to the Trash fails the repository's initialization, and Git LFS's hooks aren't installed")
    func trashFails() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)
            let error = await initializeError(app, [id])
            let decision = try #require(hooksDecision(error))
            harness.trash.setFailing(true)

            let failures = try await app.initializeLFS(in: [id], replacingHooks: LFSHooksAnswer(asked: decision, replace: true))

            #expect(failures.map(\.repositoryID) == [id])
            if case .fileSystem? = failures.first?.reason {} else {
                Issue.record("Expected a file system failure, got \(String(describing: failures.first?.reason))")
            }
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(hook("post-checkout", in: repository) == nil)
            await app.idle()
        }
    }

    // MARK: Global filters

    @Test("global filters with other values stop initializing before anything changes, and once they're updated it goes on")
    func filtersWithOtherValues() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("filter.lfs.clean", "git-lfs clean --other -- %f")
            let repository = try await repositoryUsingLFS()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            await app.integrations.launchIdle()
            let id = try #require(try await app.addRepositories([repository.path]).added.first)

            let error = await initializeError(app, [id])

            #expect(error?.reason == .lfsAttributeMismatch)
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean --other -- %f")
            #expect(hook("pre-push", in: repository) == nil)

            try await app.integrations.updateGlobalLFSFilters()
            let failures = try await app.initializeLFS(in: [id])

            #expect(failures.isEmpty)
            #expect(isLFSHook(hook("pre-push", in: repository), "pre-push"))
            await app.idle()
        }
    }

    @Test("replacing hooks moves none when the global filters have other values")
    func replacingWithFiltersOtherwise() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await repositoryUsingLFS()
            try writeHook("pre-push", customHook, in: repository)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            await app.integrations.launchIdle()
            let model = try await harness.addAndSelect(repository, to: app)
            try await setGlobalConfigValue("filter.lfs.clean", "git-lfs clean --other -- %f")

            let error = await installError(model, replacing: [hookPath("pre-push", in: repository)])

            #expect(error?.reason == .lfsAttributeMismatch)
            #expect(harness.trash.trashedPaths.isEmpty)
            #expect(hook("pre-push", in: repository) == customHook)
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean --other -- %f")
            await app.idle()
        }
    }
}
