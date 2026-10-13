// Fixtures for the Branches and MultiCommit captures: a repository with a
// remote, selected in an app with a window context, and branch, pull
// request, and SHA values.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A selected repository with `origin` and a window context.
@MainActor
struct OperationsCaptureRepository {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let local: Repository

    /// A repository whose `main` has README.md, cloned from a bare
    /// `origin`, prepared by `prepare`, then selected in an app with a
    /// window context.
    static func make(_ prepare: (Repository) async throws -> Void = { _ in }) async throws -> OperationsCaptureRepository {
        let (local, _) = try await setupRepositoryWithRemote()
        try await prepare(local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        let fixture = OperationsCaptureRepository(harness: harness, app: app, repository: repository, context: context, local: local)
        await fixture.settle()
        return fixture
    }

    /// Waits for the app, the operation's loads, and the history.
    func settle() async {
        await context.actions.idle()
        await app.idle()
        await repository.operations.enrichmentIdle()
        await repository.history.idle()
    }

    /// The branch named `name` as the refresh loaded it.
    func branch(_ name: String) throws -> Branch {
        try #require(repository.gitState.branches.all.first { $0.name == name } ?? repository.gitState.tip.branch.flatMap { $0.name == name ? $0 : nil })
    }

    /// Writes `contents` to `path` in `repository` and commits it.
    static func commitFile(_ repository: Repository, _ path: String, _ contents: String) async throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(exactFilePath: fullPath))
        try await runGit(["add", "--", path], repository)
        try await runGit(["commit", "-q", "-m", "Change \(path)"], repository)
    }
}

/// Branch, pull request, and SHA values.
enum BranchCaptureValues {
    /// A local branch.
    static func localBranch(_ name: String, sha: String = "1111111111111111111111111111111111111111", upstream: String? = nil) -> Branch {
        Branch(name: name, upstream: upstream, tip: BranchTip(sha: sha), type: .local, ref: "refs/heads/\(name)")
    }

    /// A remote branch (`origin/feature`).
    static func remoteBranch(_ name: String, sha: String = "2222222222222222222222222222222222222222") -> Branch {
        Branch(name: name, upstream: nil, tip: BranchTip(sha: sha), type: .remote, ref: "refs/remotes/\(name)")
    }

    /// An open pull request from `head` in `repository`.
    static func pullRequest(_ number: Int, head: String, in repository: GitHubRepository) -> PullRequest {
        PullRequest(
            created: Date(),
            title: "Pull request \(number)",
            pullRequestNumber: number,
            head: PullRequestRef(ref: head, sha: "3333333333333333333333333333333333333333", gitHubRepository: repository),
            base: PullRequestRef(ref: "main", sha: "4444444444444444444444444444444444444444", gitHubRepository: repository),
            author: "octocat",
            draft: false,
            body: ""
        )
    }

    /// A SHA made of one digit.
    static func sha(_ digit: Int) -> String {
        String(repeating: String(digit), count: 40)
    }
}
