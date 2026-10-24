// URL and command line actions through `AppModel.handle(_:confirmed:)`:
// matching repositories, clone requests and their continuation, branches
// (asked first, then fetched and checked out, decisions thrown), pull
// requests from a mock GitHub, files revealed and refused, folders, and the
// command line's clone.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("External actions", .offline) @MainActor
struct ExternalActionsTests {
    private func url(_ string: String) throws -> ExternalAction {
        .url(try #require(URL(string: string)))
    }

    private func opened(_ result: ExternalActionResult) throws -> OpenedRepository {
        guard case .opened(let opened) = result else {
            Issue.record("Expected an opened repository, got \(result)")
            throw OpenFailure()
        }
        return opened
    }

    private struct OpenFailure: Error {}

    /// A repository with a commit on `main` and a bare `origin`, associated
    /// with `gitHubRepository` and assigned `testAccount`, in a loaded app;
    /// not selected.
    private func makeRepository(
        _ gitHubRepository: GitHubRepository = ModelFixtures.gitHubRepository(),
        responder: PromptCenter.Responder? = PromptResponder.failing()
    ) async throws -> (harness: AppHarness, app: AppModel, model: RepositoryModel, local: Repository, remote: Repository) {
        let (local, remote) = try await setupRepositoryWithRemote()
        let harness = try AppHarness(responder: responder)
        let app = await harness.loadedApp()
        await app.accounts.idle()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        app.updateRecord(id) {
            $0.gitHubRepository = gitHubRepository
            $0.accountLogin = testAccount.login
        }
        return (harness, app, try #require(app.repository(id)), local, remote)
    }

    // MARK: Matching

    @Test("a URL for a repository in the list selects it")
    func selectsMatchingRepository() async throws {
        let (_, app, model, _, _) = try await makeRepository()
        let other = try #require(try await app.addRepositories([try setupEmptyRepository().path]).added.first)
        app.select(.repository(other))

        let result = try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app"))
        #expect(result == .opened(OpenedRepository(repositoryID: model.id)))
        #expect(app.selection == .repository(model.id))
        await app.idle()
    }

    @Test("matching ignores case, and a fork's parent matches")
    func matching() async throws {
        let parent = ModelFixtures.gitHubRepository(owner: "upstream", name: "app", dbID: 2)
        let (_, app, model, _, _) = try await makeRepository(ModelFixtures.gitHubRepository(owner: "me", name: "app", parent: parent))

        #expect(app.repositoryMatchingURL("https://GitHub.com/ME/App") == model.id)
        #expect(app.repositoryMatchingURL("https://github.com/upstream/app.git") == model.id)
        #expect(app.repositoryMatchingURL("git@github.com:upstream/app.git") == model.id)
        #expect(app.repositoryMatchingURL("https://github.com/someone/app") == nil)
        #expect(app.repositoryMatchingURL("https://example.com/me/app") == nil)
        await app.idle()
    }

    @Test("a repository without a GitHub repository never matches a URL")
    func localRepositoriesDontMatch() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let (local, _) = try await setupRepositoryWithRemote()
        _ = try await app.addRepositories([local.path])

        let result = try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app"))
        guard case .cloneRequested(let request) = result else {
            Issue.record("Expected a clone request, got \(result)")
            return
        }
        #expect(request.url == "https://github.com/octocat/app")
        await app.idle()
    }

    // MARK: Clone requests

    @Test("a URL no repository matches asks for a clone; continuing in the clone checks out the branch and reveals the file")
    func cloneRequestAndContinuation() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let result = try await app.handle(try url(
            "espalier://openRepo/https://github.com/octocat/other?branch=feature&filepath=docs%2Fguide.md"
        ))
        guard case .cloneRequested(let request) = result else {
            Issue.record("Expected a clone request, got \(result)")
            return
        }
        #expect(request.url == "https://github.com/octocat/other")
        #expect(request.action.branch == "feature")
        #expect(app.selection == nil)

        // What the clone produces: a repository whose origin has `feature`.
        let (seed, remote) = try await setupRepositoryWithRemote()
        try await runGit(["checkout", "-b", "feature"], seed)
        try await commitFile(seed, "docs/guide.md", "Guide\n")
        try await runGit(["push", "origin", "feature"], seed)
        let clone = try await cloneRepository(remote)
        let id = try #require(try await app.addRepositories([clone.path]).added.first)

        // The link's branch asks first in the clone too.
        let question = await #expect(throws: OperationError.self) {
            try await app.continueExternalAction(request, in: id)
        }
        guard case .confirmationRequired(let confirmation)? = question?.reason else {
            Issue.record("Expected a question, got \(String(describing: question))")
            return
        }
        let cloneName = try #require(app.record(id)).displayName
        #expect(confirmation.details == .linkedBranch(repository: cloneName, branch: "feature"))
        #expect(harness.workspace.revealedPaths.isEmpty)

        let continued = try opened(try await app.continueExternalAction(request, in: id, confirmed: [.checkoutLinkedBranch]))
        let model = try #require(app.repository(id))
        #expect(app.selection == .repository(id))
        #expect(model.gitState.tip.branch?.name == "feature")
        #expect(model.gitState.tip.branch?.upstream == "origin/feature")
        guard case .checkedOut? = continued.checkout else {
            Issue.record("Expected a checkout, got \(String(describing: continued.checkout))")
            return
        }
        let guide = POSIXPath.join(clone.path, "docs", "guide.md")
        #expect(continued.revealedFile == guide)
        #expect(harness.workspace.revealedPaths == [guide])
        await app.idle()
    }

    // MARK: Branches

    @Test("a branch asks first, naming the repository and the branch, with nothing fetched, checked out, or shown; confirmed, a branch pushed elsewhere is fetched, then checked out")
    func asksThenFetchesAndChecksOut() async throws {
        let (harness, app, model, local, remote) = try await makeRepository()
        let other = try await cloneRepository(remote)
        try await runGit(["checkout", "-b", "topic"], other)
        try await commitFile(other, "topic.txt", "topic\n")
        try await runGit(["push", "origin", "topic"], other)
        let action = try url("espalier://openRepo/https://github.com/octocat/app?branch=topic&filepath=README.md")

        let question = await #expect(throws: OperationError.self) {
            try await app.handle(action)
        }
        guard case .confirmationRequired(let confirmation)? = question?.reason else {
            Issue.record("Expected a question, got \(String(describing: question))")
            return
        }
        #expect(confirmation.kind == .checkoutLinkedBranch)
        #expect(confirmation.details == .linkedBranch(repository: "app", branch: "topic"))
        #expect(question?.repositoryID == model.id)
        // The repository shows, and nothing else ran: what cancelling leaves.
        #expect(app.selection == .repository(model.id))
        #expect(try await resolveRef("refs/remotes/origin/topic", in: local) == nil)
        #expect(model.gitState.tip.branch?.name == "main")
        #expect(harness.workspace.revealedPaths.isEmpty)

        let result = try opened(try await app.handle(action, confirmed: [.checkoutLinkedBranch]))
        #expect(result.fetchError == nil)
        #expect(model.gitState.tip.branch?.name == "topic")
        #expect(try await localBranchNames(local).contains("topic"))
        #expect(result.revealedFile == POSIXPath.join(local.path, "README.md"))
        await app.idle()
    }

    @Test("a checkout that needs the user's decision is thrown, after the file is revealed")
    func checkoutDecisionIsThrown() async throws {
        let (harness, app, model, local, _) = try await makeRepository()
        try await runGit(["branch", "other"], local)
        try harness.write("README.md", "Changed\n", in: local)

        let error = await #expect(throws: OperationError.self) {
            try await app.handle(
                try url("espalier://openRepo/https://github.com/octocat/app?branch=other&filepath=README.md"),
                confirmed: [.checkoutLinkedBranch]
            )
        }
        #expect(error?.reason == .decisionRequired(.uncommittedChanges(
            currentBranch: "main",
            targetBranch: "other"
        )))
        #expect(error?.repositoryID == model.id)
        guard case .checkout(let branch)? = error?.gitContext else {
            Issue.record("Expected the branch in the error's context")
            return
        }
        #expect(branch.name == "other")
        #expect(harness.workspace.revealedPaths == [POSIXPath.join(local.path, "README.md")])
        #expect(model.gitState.tip.branch?.name == "main")

        // Answering it checks the branch out.
        #expect(try await model.branches.checkout(branch, strategy: .moveToNewBranch) == .checkedOut(branch))
        await app.idle()
    }

    @Test("the current branch asks nothing and is neither fetched nor checked out; one the repository doesn't have asks, then says it isn't there")
    func noCheckout() async throws {
        let (_, app, model, local, remote) = try await makeRepository()
        try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
        let fetched = try await resolveRef("refs/remotes/origin/main", in: local)

        let current = try opened(try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app?branch=main")))
        #expect(current.checkout == nil)
        #expect(try await resolveRef("refs/remotes/origin/main", in: local) == fetched)

        let unknown = try url("espalier://openRepo/https://github.com/octocat/app?branch=nope")
        await #expect(throws: OperationError.self) {
            try await app.handle(unknown)
        }
        do throws(OperationError) {
            _ = try await app.handle(unknown, confirmed: [.checkoutLinkedBranch])
            Issue.record("Expected a branch the repository doesn't have to throw")
        } catch {
            if case .precondition = error.reason {} else {
                Issue.record("Expected a precondition, got \(error.reason)")
            }
            #expect(error.repositoryID == model.id)
        }
        #expect(app.selection == .repository(model.id))
        #expect(model.gitState.tip.branch?.name == "main")
        await app.idle()
    }

    // MARK: Files

    @Test("never reveals a file that is absolute, outside the repository, or missing")
    func refusedFiles() async throws {
        let (harness, app, _, local, _) = try await makeRepository()
        // A folder next to the repository whose name starts with the
        // repository's: a plain prefix check would let it through.
        let sibling = local.path + "-other"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(filePath: POSIXPath.join(sibling, "file.txt")))
        let outside = try createTempDirectory()
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(local.path, "link"), withDestinationPath: outside)

        let base = "espalier://openRepo/https://github.com/octocat/app?filepath="
        for path in ["%2Fetc%2Fhosts", "..%2Fsecret", "..%2F\(POSIXPath.basename(sibling))%2Ffile.txt", "missing.txt", "link"] {
            let result = try opened(try await app.handle(try url(base + path)))
            #expect(result.revealedFile == nil, "\(path)")
        }
        #expect(harness.workspace.revealedPaths.isEmpty)

        let inside = try opened(try await app.handle(try url(base + "README.md")))
        #expect(inside.revealedFile == POSIXPath.join(local.path, "README.md"))
        await app.idle()
    }

    @Test("resolveWithin keeps paths at or under the root")
    func resolveWithinRoot() throws {
        let root = try createTempDirectory()
        try FileManager.default.createDirectory(atPath: POSIXPath.join(root, "a"), withIntermediateDirectories: false)
        #expect(resolveWithin(root, "a") == POSIXPath.join(root, "a"))
        #expect(resolveWithin(root, ".") == root)
        #expect(resolveWithin(root, "a", "..") == root)
        #expect(resolveWithin(root, "..") == nil)
        #expect(resolveWithin("", "a") == nil)
        #expect(resolveWithin(root, "a\u{0}b") == nil)
    }

    // MARK: Pull requests

    private func pullRequestResponse(
        head: (owner: String, name: String)? = ("someone", "app"),
        base: (owner: String, name: String) = ("octocat", "app")
    ) -> MockGitHub.Response {
        func repository(_ owner: String, _ name: String) -> APIRepository {
            createMockAPIRepository(
                cloneURL: "https://github.com/\(owner)/\(name).git",
                htmlURL: "https://github.com/\(owner)/\(name)",
                name: name,
                owner: createMockAPIIdentity(login: owner)
            )
        }
        return .json(encoding: APIPullRequest(
            number: 12,
            title: "Fix the thing",
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-02T00:00:00Z",
            user: createMockAPIIdentity(login: "someone"),
            head: APIPullRequestRef(ref: "fix-thing", sha: String(repeating: "a", count: 40), repo: head.map { repository($0.owner, $0.name) }),
            base: APIPullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), repo: repository(base.owner, base.name)),
            body: nil,
            state: .open
        ))
    }

    @Test("a pull request link opens the repository its head belongs to, else its base, and names the pull request", .hangGuard(minutes: 5))
    func pullRequest() async throws {
        let (harness, app, base, _, _) = try await makeRepository()
        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app/pulls/12", respond: pullRequestResponse())

        let action = try url("espalier://openRepo/https://github.com/octocat/app?pr=12&branch=pr%2F12")
        let fromBase = try opened(try await app.handle(action))
        #expect(fromBase.repositoryID == base.id)
        let link = try #require(fromBase.pullRequest)
        #expect(link.number == 12)
        #expect(link.title == "Fix the thing")
        #expect(link.headRepositoryOwner == "someone")
        #expect(link.headCloneURL == "https://github.com/someone/app.git")
        #expect(link.headRef == "fix-thing")
        // The pull request GitHub returned, to show.
        #expect(link.pullRequest?.pullRequestNumber == 12)
        #expect(link.pullRequest?.base.gitHubRepository.fullName == "octocat/app")
        #expect(link.pullRequest?.head.ref == "fix-thing")
        #expect(fromBase.checkout == nil)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app/pulls/12").first?.header("Authorization") == "Bearer token")

        let fork = try #require(try await app.addRepositories([try await setupRepositoryWithRemote().local.path]).added.first)
        app.updateRecord(fork) { $0.gitHubRepository = ModelFixtures.gitHubRepository(owner: "someone", name: "app", dbID: 3) }
        let fromHead = try opened(try await app.handle(action))
        #expect(fromHead.repositoryID == fork)
        #expect(app.selection == .repository(fork))
        await app.idle()
    }

    @Test("a pull request from a fork that contributes to itself: the link opens the fork, shows the link's pull request, and, once confirmed, checks out its branch there", .hangGuard(minutes: 5))
    func pullRequestFromSelfContributingFork() async throws {
        // hubot's fork, with a `patch` branch, cloned: the clone's origin is
        // the fork on GitHub, with `patch` fetched. A proxy that refuses
        // every connection keeps git off the network.
        let (seed, fork) = try await setupRepositoryWithRemote()
        try await runGit(["checkout", "-b", "patch"], seed)
        try await commitFile(seed, "patch.txt", "patch\n")
        try await runGit(["push", "origin", "patch"], seed)
        let local = try await cloneRepository(fork)
        try await runGit(["remote", "set-url", "origin", "https://github.com/hubot/hello.git"], local)
        try await runGit(["config", "http.proxy", "http://127.0.0.1:1"], local)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        try await harness.signIn([testAccount], to: app)
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        let upstream = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello", dbID: 1)
        app.updateRecord(id) { record in
            record.gitHubRepository = ModelFixtures.gitHubRepository(owner: "hubot", name: "hello", dbID: 2, parent: upstream)
            record.accountLogin = testAccount.login
            record.workflowPreferences.forkContributionTarget = .fork
        }
        let record = try #require(app.record(id))
        // The fork's own pull requests are the ones its place lists.
        #expect(getNonForkGitHubRepository(record)?.fullName == "hubot/hello")

        func repository(_ owner: String, cloneURL: String) -> APIRepository {
            createMockAPIRepository(
                cloneURL: cloneURL,
                htmlURL: "https://github.com/\(owner)/hello",
                name: "hello",
                owner: createMockAPIIdentity(login: owner)
            )
        }
        harness.gitHub.on("GET", "/repos/octocat/hello/pulls/7", respond: .json(encoding: APIPullRequest(
            number: 7,
            title: "Patch the thing",
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-02T00:00:00Z",
            user: createMockAPIIdentity(login: "hubot"),
            head: APIPullRequestRef(ref: "patch", sha: String(repeating: "a", count: 40), repo: repository("hubot", cloneURL: "https://github.com/hubot/hello.git")),
            base: APIPullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), repo: repository("octocat", cloneURL: "https://github.com/octocat/hello.git")),
            body: nil,
            state: .open
        )))

        let opened = try opened(try await app.handle(try url("espalier://openRepo/https://github.com/octocat/hello?pr=7")))
        #expect(opened.repositoryID == id)
        let link = try #require(opened.pullRequest)
        #expect(link.pullRequest?.title == "Patch the thing")
        #expect(link.pullRequest?.base.gitHubRepository.fullName == "octocat/hello")

        // The link returns once the branches are loaded, though adding the
        // fork's upstream remote meanwhile superseded the selection's pass.
        let model = try #require(app.repository(id))
        #expect(model.gitState.branches.all.contains { $0.name == "origin/patch" })
        // The checkout asks first, naming no remote: the fork is origin.
        let question = await #expect(throws: OperationError.self) {
            try await model.gitHub.checkout(link)
        }
        guard case .confirmationRequired(let confirmation)? = question?.reason else {
            Issue.record("Expected a question, got \(String(describing: question))")
            return
        }
        let name = try #require(app.record(id)).displayName
        #expect(confirmation.details == .linkedPullRequest(repository: name, number: 7, title: "Patch the thing", forkRemote: nil))
        #expect(model.gitState.tip.branch?.name == "main")
        _ = try await model.gitHub.checkout(link, confirmed: [.checkoutLinkedPullRequest])
        let branch = try #require(model.gitState.tip.branch)
        #expect(branch.name == "patch")
        #expect(branch.upstream == "origin/patch")
        // The branch is the fork's own: no remote was added for it.
        #expect(!(try await remoteURLs(local).keys.contains("espalier-hubot")))
        await app.idle()
    }

    @Test("a pull request link whose repository's account is signed out asks to sign in to it again, and throws when that's cancelled; one GitHub can't find throws", .hangGuard(minutes: 5))
    func pullRequestErrors() async throws {
        let (harness, app, _, _, _) = try await makeRepository(responder: PromptResponder.dismissing)
        let action = try url("espalier://openRepo/https://github.com/octocat/app?pr=12")

        await #expect(throws: OperationError.self) {
            try await app.handle(action)
        }
        guard case .repositoryAccount(let request)? = harness.prompts.history.first else {
            Issue.record("Expected the question about the repository's account, got \(harness.prompts.history)")
            return
        }
        #expect(request.signedOutLogin == testAccount.login)
        #expect(request.endpoint == testAccount.endpoint)

        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app/pulls/12", respond: .status(404))
        let notFound = await #expect(throws: OperationError.self) {
            try await app.handle(action)
        }
        guard case .api(let failure)? = notFound?.reason else {
            Issue.record("Expected an API failure, got \(String(describing: notFound))")
            return
        }
        #expect(failure.status == 404)
        await app.idle()
    }

    @Test("a pull request of a repository not in the list asks for a clone, then names it in the clone; one whose fork was deleted says so", .hangGuard(minutes: 5))
    func pullRequestClone() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app", respond: .json(encoding: APIFullRepository(
            repository: createMockAPIRepository(
                cloneURL: "https://github.com/octocat/app.git",
                htmlURL: "https://github.com/octocat/app",
                name: "app",
                owner: createMockAPIIdentity(login: "octocat")
            ),
            permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
        )))
        harness.gitHub.on("GET", "/repos/octocat/app/pulls/12", respond: pullRequestResponse(head: nil))

        let result = try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app?pr=12"))
        guard case .cloneRequested(let request) = result else {
            Issue.record("Expected a clone request, got \(result)")
            return
        }
        #expect(request.url == "https://github.com/octocat/app")

        let (local, _) = try await setupRepositoryWithRemote()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        // Not associated with GitHub: the pull request can't be checked out.
        #expect(try opened(try await app.continueExternalAction(request, in: id)).pullRequest == nil)
        // Associated, but the head repository was deleted: it says so, with
        // the repository selected.
        app.updateRecord(id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        do throws(OperationError) {
            _ = try await app.continueExternalAction(request, in: id)
            Issue.record("Expected a pull request whose fork was deleted to throw")
        } catch {
            if case .precondition = error.reason {} else {
                Issue.record("Expected a precondition, got \(error.reason)")
            }
            #expect(error.repositoryID == id)
        }
        #expect(app.selection == .repository(id))
        await app.idle()
    }

    // MARK: Folders

    @Test("folders: the first added, else existing, repository is selected; invalid ones are reported as Add does")
    func folders() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let existing = try setupEmptyRepository()
        let existingID = try #require(try await app.addRepositories([existing.path]).added.first)
        let new = try setupEmptyRepository()
        let notRepository = try createTempDirectory()

        let result = try await app.handle(.folders([existing.path, new.path, notRepository]))
        guard case .addedRepositories(let added) = result else {
            Issue.record("Expected added repositories, got \(result)")
            return
        }
        #expect(added.existing == [existingID])
        #expect(added.added.count == 1)
        #expect(added.invalidPaths == [notRepository])
        #expect(app.selection == added.added.first.map(AppSelection.repository))

        _ = try await app.handle(.folders([POSIXPath.join(existing.path, ".git", "..")]))
        #expect(app.selection == .repository(existingID))
        await app.idle()
    }

    @Test("a folder that's a worktree of a repository in the list opens one repository")
    func worktreeFolder() async throws {
        let main = try await setupTwoCommitRepo()
        let worktree = POSIXPath.join(try createTempDirectory(), "feature")
        try await runGit(["worktree", "add", "-b", "feature", worktree], main)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let mainID = try #require(try await app.addRepositories([main.path]).added.first)

        let result = try await app.handle(.folders([worktree]))
        guard case .addedRepositories(let added) = result else {
            Issue.record("Expected added repositories, got \(result)")
            return
        }
        // The listed repository switches to the worktree; nothing is added.
        #expect(added.added.isEmpty)
        #expect(added.existing == [mainID])
        #expect(added.repositories == [mainID])
        #expect(app.repositories.count == 1)
        #expect(app.record(mainID)?.path == worktree)
        #expect(app.selection == .repository(mainID))
        await app.idle()
    }

    // MARK: Other actions

    @Test("an unknown URL is ignored")
    func unknownURL() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let result = try await app.handle(try url("espalier://nothing/https://github.com/octocat/app"))
        #expect(result == .ignored("Espalier can't open this link: espalier://nothing/https://github.com/octocat/app"))
    }

    @Test("the command line's clone: owner/name means GitHub.com")
    func commandLineClone() async throws {
        let (_, app, model, _, _) = try await makeRepository()
        let result = try opened(try await app.handle(.clone(url: "octocat/app", branch: nil)))
        #expect(result.repositoryID == model.id)

        let missing = try await app.handle(.clone(url: "octocat/elsewhere", branch: "dev"))
        guard case .cloneRequested(let request) = missing else {
            Issue.record("Expected a clone request, got \(missing)")
            return
        }
        #expect(request.url == "https://github.com/octocat/elsewhere")
        #expect(request.action.branch == "dev")
        await app.idle()
    }

    @Test("a missing repository the URL names is selected, and nothing else runs in it")
    func missingRepository() async throws {
        let (harness, app, model, local, _) = try await makeRepository()
        try FileManager.default.removeItem(atPath: local.path)
        app.setMissing(true, for: model.id)

        let result = try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app?branch=main&filepath=README.md"))
        #expect(result == .opened(OpenedRepository(repositoryID: model.id)))
        #expect(app.selection == .repository(model.id))
        #expect(harness.workspace.revealedPaths.isEmpty)
        await app.idle()
    }

    @Test("an action that arrives before the list loads waits for it")
    func waitsForTheList() async throws {
        let harness = try AppHarness()
        let first = await harness.loadedApp()
        let (local, _) = try await setupRepositoryWithRemote()
        let id = try #require(try await first.addRepositories([local.path]).added.first)
        first.updateRecord(id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        await first.prepareForTermination()

        let app = harness.makeApp()
        #expect(app.loadState == .notLoaded)
        let result = try await app.handle(try url("espalier://openRepo/https://github.com/octocat/app"))
        #expect(app.loadState == .ready)
        #expect(result == .opened(OpenedRepository(repositoryID: id)))
        await app.idle()
    }
}
