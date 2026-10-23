// Creating a pull request in Espalier: what has to happen before it can be
// written (the branch on GitHub; without an account, GitHub's form in the
// browser instead), the title and body it starts with (as GitHub's own form
// seeds them), and creating it through GitHub's API, after which the list of
// open pull requests is refreshed so it shows there.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "pull-requests")

/// What `prepareToCreatePullRequest(base:choice:)` found.
public enum PullRequestCreationStart: Sendable, Equatable {
    /// The branch is on GitHub: write the pull request from `head` (the
    /// current branch as it is now, with its upstream), then create it with
    /// `createPullRequest(_:)`.
    case ready(head: Branch)
    /// Nothing ran: ask, then call again with the choice.
    case choiceRequired(CreatePullRequestStep)
    /// The repository has no remote: publish it first (from the push).
    case publishRepositoryRequired
    /// No account is signed in to the repository's server, so GitHub's form
    /// opened in the browser.
    case openedInBrowser(URL)
}

/// A pull request to create.
public struct NewPullRequest: Sendable, Equatable {
    public var title: String
    public var body: String
    /// The branch its changes are on: the current branch, published.
    public var head: Branch
    /// The branch it merges into: one on the pull request's remote
    /// (`PullRequestPreviewModel.baseBranchCandidates`).
    public var base: Branch
    /// Whether it opens as a draft.
    public var isDraft: Bool

    public init(title: String, body: String, head: Branch, base: Branch, isDraft: Bool) {
        self.title = title
        self.body = body
        self.head = head
        self.base = base
        self.isDraft = isDraft
    }
}

/// The title and body a new pull request starts with.
public struct PullRequestSeed: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// The title and body as GitHub's form seeds them: the only commit's
    /// summary and body, else a title from the branch's name and no body. A
    /// template with any text replaces the body.
    ///
    /// - Parameters:
    ///   - commits: The pull request's commits; two are enough to know there's
    ///     more than one.
    ///   - branchName: The branch's name on GitHub.
    ///   - template: The repository's pull request template, if it has one.
    public static func make(commits: [Commit], branchName: String, template: String?) -> PullRequestSeed {
        let only = commits.count == 1 ? commits.first : nil
        let commitBody = only.map { JSCompat.trim($0.body) } ?? ""
        let templateBody = template.flatMap { JSCompat.trim($0).isEmpty ? nil : $0 }
        return PullRequestSeed(
            title: only?.summary ?? Self.title(fromBranchName: branchName),
            body: templateBody ?? commitBody
        )
    }

    /// A title from a branch's name, as GitHub writes one: hyphens and
    /// underscores become spaces, and the first letter a capital
    /// (`fix-sign_in` becomes "Fix sign in").
    public static func title(fromBranchName name: String) -> String {
        let spaced = name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else {
            return spaced
        }
        return first.uppercased() + spaced.dropFirst()
    }
}

extension RepositoryGitHubModel {
    // MARK: Creating in Espalier

    /// "Create Pull Request": what has to happen before the pull request
    /// from the current branch can be written.
    ///
    /// A branch without an upstream must be published first, and one with
    /// unpushed commits may push them first: without `choice`, nothing runs
    /// and `.choiceRequired` carries the question. With `.pushFirst`, the
    /// branch is published or pushed, then it's `.ready`; with
    /// `.createWithoutPushing`, it's `.ready` at once. Without an account
    /// for the repository's server, it's `createPullRequest(base:choice:)`,
    /// which opens GitHub's form in the browser into `base` (the default
    /// branch when nil).
    ///
    /// - Throws: `.precondition` without a GitHub repository or a current
    ///   branch; the push's errors.
    public func prepareToCreatePullRequest(
        base: Branch? = nil,
        choice: CreatePullRequestChoice? = nil
    ) async throws(OperationError) -> PullRequestCreationStart {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .createPullRequest)
        }
        guard let target = getNonForkGitHubRepository(repository.record) else {
            throw OperationError(.precondition("Only repositories on GitHub can have pull requests."), operation: .createPullRequest, repositoryID: repository.id)
        }
        // Without an account on the server, the pull request is created on
        // GitHub's form. A repository whose account isn't signed in, or that
        // has none while accounts are signed in to its server, asks for one.
        var hasAccount = app.accounts.account(for: repository.record, on: target.endpoint) != nil
        if !hasAccount, repository.record.accountLogin != nil || !app.accounts.accounts(onEndpoint: target.endpoint).isEmpty {
            guard let account = await app.ensureRepositoryAccount(repository.id), account.endpoint == target.endpoint else {
                throw OperationError(.cancelled(.userCancelled), operation: .createPullRequest, repositoryID: repository.id)
            }
            hasAccount = true
        }
        guard hasAccount else {
            switch try await createPullRequest(base: base, choice: choice) {
            case .opened(let url): return .openedInBrowser(url)
            case .choiceRequired(let step): return .choiceRequired(step)
            case .publishRepositoryRequired: return .publishRepositoryRequired
            }
        }
        guard case .valid(let compareBranch) = repository.gitState.tip else {
            throw OperationError(.precondition("The current branch isn't known yet."), operation: .createPullRequest, repositoryID: repository.id)
        }

        let step: CreatePullRequestStep?
        if let aheadBehind = repository.gitState.aheadBehind {
            step = aheadBehind.ahead > 0 ? .pushCommits(compareBranch, unpushedCommits: aheadBehind.ahead) : nil
        } else {
            step = .publishBranch(compareBranch)
        }

        if let step {
            switch (step, choice) {
            case (_, nil), (.publishBranch, .createWithoutPushing?):
                return .choiceRequired(step)
            case (.publishBranch, .pushFirst?):
                if case .publishRepositoryRequired = try await repository.sync.publishBranch() {
                    return .publishRepositoryRequired
                }
            case (.pushCommits, .pushFirst?):
                if case .publishRepositoryRequired = try await repository.sync.push() {
                    return .publishRepositoryRequired
                }
            case (.pushCommits, .createWithoutPushing?):
                break
            }
        }

        // The branch as it is now (pushing gave it an upstream).
        return .ready(head: repository.gitState.tip.branch ?? compareBranch)
    }

    /// The branch a pull request from `head` comes from, as GitHub shows
    /// it: its name on GitHub, after the fork's owner (`hubot:feature`) when
    /// the pull request goes to the fork's parent.
    public func pullRequestHeadName(_ head: Branch) -> String {
        let name = pullRequestBranchName(head)
        guard let record = repository?.record, let owner = forkOwner(record) else {
            return name
        }
        return "\(owner):\(name)"
    }

    /// The title and body a pull request from `head` into `base` starts
    /// with (`PullRequestSeed.make`): from the commits on GitHub's side of
    /// `head` (its upstream, when it's been fetched) that `base` doesn't
    /// have, and the repository's pull request template on the default
    /// branch (where GitHub reads it), else on `base`.
    ///
    /// GitHub's template is the first `pull_request_template.md` in
    /// `.github`, the root, or `docs`, its name and its folder's matched
    /// without case. Without a base there are no commits to seed from.
    public func pullRequestSeed(head: Branch, base: Branch?) async -> PullRequestSeed {
        let branchName = pullRequestBranchName(head)
        guard let repository else {
            return PullRequestSeed.make(commits: [], branchName: branchName, template: nil)
        }
        let branches = repository.gitState.branches
        let upstreamTip = head.upstream.flatMap { upstream in
            branches.all.first { $0.type == .remote && JSCompat.strictEquals($0.name, upstream) }?.tip.sha
        }
        let headSHA = upstreamTip ?? head.tip.sha
        let baseSHA = base?.tip.sha
        let templateCommit = branches.defaultBranch?.tip.sha ?? baseSHA ?? headSHA
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes { () async -> PullRequestSeed in
            var commits: [Commit] = []
            if let baseSHA {
                commits = (try? await getCommits(gitRepository, revRange(baseSHA, headSHA), limit: 2)) ?? []
            }
            let template = await readPullRequestTemplate(gitRepository, at: templateCommit)
            return PullRequestSeed.make(commits: commits, branchName: branchName, template: template)
        }
    }

    /// Creates `request` on GitHub, in the repository's GitHub repository
    /// (the parent, for a fork that contributes to it), then refreshes the
    /// open pull requests so it's listed.
    ///
    /// - Returns: The new pull request: the list's, else as GitHub described
    ///   it.
    /// - Throws: `.precondition` without a GitHub repository, an account for
    ///   it, or a title; `.api` with what GitHub said
    ///   (`CreatePullRequestError`, the error underneath) and its status;
    ///   `.cancelled` when the task is cancelled.
    @discardableResult
    public func createPullRequest(_ request: NewPullRequest) async throws(OperationError) -> PullRequest {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .createPullRequest)
        }
        let id = repository.id
        guard let gitHubRepository = repository.record.gitHubRepository, let target = getNonForkGitHubRepository(repository.record) else {
            throw OperationError(.precondition("Only repositories on GitHub can have pull requests."), operation: .createPullRequest, repositoryID: id)
        }
        guard let account = app.accounts.account(for: repository.record, on: target.endpoint) else {
            throw OperationError(
                .precondition("Sign in to \(getHTMLURL(target.endpoint)) to create pull requests."),
                operation: .createPullRequest,
                repositoryID: id
            )
        }
        let title = JSCompat.trim(request.title)
        guard !title.isEmpty else {
            throw OperationError(.precondition("Enter a title for the pull request."), operation: .createPullRequest, repositoryID: id)
        }

        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let created: APIPullRequest
        do {
            created = try await api.createPullRequest(
                owner: target.owner.login,
                name: target.name,
                title: title,
                body: request.body,
                head: pullRequestBranchName(request.head),
                headOwner: forkOwner(repository.record),
                base: pullRequestBranchName(request.base),
                draft: request.isDraft
            )
        } catch {
            if error is CancellationError {
                throw OperationError(.cancelled(.taskCancelled), operation: .createPullRequest, repositoryID: id, underlying: error)
            }
            throw OperationError(.api(creationFailure(error)), operation: .createPullRequest, repositoryID: id, underlying: error)
        }
        logger.info("Created pull request #\(created.number, privacy: .public) in \(target.fullName, privacy: .private)")

        // A refresh already running when GitHub created it is joined, and
        // may not have it: one more then.
        await refreshPullRequests()
        if !openPullRequests.contains(where: { $0.pullRequestNumber == created.number }) {
            await refreshPullRequests()
        }
        if let listed = openPullRequests.first(where: { $0.pullRequestNumber == created.number }) {
            return listed
        }
        if let model = repository.app?.background.pullRequests.store.model(for: created, in: target) {
            return model
        }
        // GitHub's answer without its repositories: the ones it was created
        // between.
        return PullRequest(
            created: parseGitHubTimestamp(created.createdAt) ?? repository.environment.scheduler.now,
            title: created.title,
            pullRequestNumber: created.number,
            head: PullRequestRef(ref: created.head.ref, sha: created.head.sha, gitHubRepository: gitHubRepository),
            base: PullRequestRef(ref: created.base.ref, sha: created.base.sha, gitHubRepository: target),
            author: created.user?.login ?? account.login,
            authorAvatarURL: created.user.flatMap { $0.avatarURL.isEmpty ? nil : $0.avatarURL },
            draft: created.draft ?? request.isDraft,
            body: created.body ?? ""
        )
    }
}

// MARK: Helpers

/// A branch's name on GitHub: a remote branch's without its remote, a local
/// branch's upstream's, else its own.
func pullRequestBranchName(_ branch: Branch) -> String {
    if branch.type == .remote {
        return branch.nameWithoutRemote
    }
    return branch.upstreamWithoutRemote ?? branch.name
}

/// The fork's owner, for a fork whose pull requests go to its parent; nil
/// otherwise.
private func forkOwner(_ record: RepositoryRecord) -> String? {
    isForkedRepositoryContributingToParent(record) ? record.gitHubRepository?.owner.login : nil
}

/// A failed creation as `OperationError.Reason.api` carries it.
private func creationFailure(_ error: any Error) -> APIFailure {
    if let error = error as? CreatePullRequestError {
        return APIFailure(message: error.message, status: error.status)
    }
    return apiFailure(from: error)
}

// MARK: The template

/// Where GitHub looks for a pull request template, in its order: `.github`,
/// the root (empty), then `docs`.
private let pullRequestTemplateFolders = [".github", "", "docs"]

/// The template's name, matched without case.
private let pullRequestTemplateName = "pull_request_template.md"

/// The most of a template that's read.
private let maximumTemplateBytes = 64 * 1024

/// The pull request template at `commit`: the first
/// `pull_request_template.md` in `.github`, the root, or `docs`, its name
/// and its folder's matched without case (ASCII case, as GitHub matches
/// them). A symbolic link isn't one. Nil when there's none, or it can't be
/// read.
@concurrent
func readPullRequestTemplate(_ repository: Repository, at commit: String) async -> String? {
    guard let root = await treeEntries(repository, commit) else {
        return nil
    }
    for folder in pullRequestTemplateFolders {
        var entries = root
        var prefix = ""
        if !folder.isEmpty {
            guard let tree = root.first(where: { $0.isTree && equalsIgnoringASCIICase($0.name, folder) }),
                  let listed = await treeEntries(repository, tree.object)
            else {
                continue
            }
            entries = listed
            prefix = "\(tree.name)/"
        }
        guard let file = entries.first(where: { $0.isFile && equalsIgnoringASCIICase($0.name, pullRequestTemplateName) }) else {
            continue
        }
        guard let data = try? await getPartialBlobContents(repository, commit, prefix + file.name, maximumTemplateBytes) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
    return nil
}

/// An entry of a tree, as `git ls-tree` lists it.
private struct TreeEntry: Sendable {
    let mode: String
    let type: String
    let object: String
    let name: String

    var isTree: Bool {
        type == "tree"
    }

    /// A file: a blob that isn't a symbolic link.
    var isFile: Bool {
        type == "blob" && mode != "120000"
    }
}

/// The entries of `treeish` (a commit or a tree), without recursing; nil
/// when git can't list it.
private func treeEntries(_ repository: Repository, _ treeish: String) async -> [TreeEntry]? {
    guard !treeish.isEmpty, !JSCompat.startsWith(treeish, "-"),
          let result = try? await git(
              ["ls-tree", "-z", treeish],
              repository.path,
              "listPullRequestTemplateTree",
              options: GitExecutionOptions(successExitCodes: [0, 128])
          ),
          result.exitCode == 0
    else {
        return nil
    }
    func text(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
    // Each entry is `<mode> <type> <object>\t<name>`, ended by a NUL.
    return result.stdoutData.split(separator: 0).compactMap { record -> TreeEntry? in
        guard let tab = record.firstIndex(of: 0x09) else {
            return nil
        }
        let fields = record[record.startIndex..<tab].split(separator: 0x20)
        guard fields.count == 3 else {
            return nil
        }
        return TreeEntry(
            mode: text(fields[0]),
            type: text(fields[1]),
            object: text(fields[2]),
            name: text(record[record.index(after: tab)...])
        )
    }
}

/// Whether `name` is `lowercase` (ASCII) with any ASCII letters in either
/// case.
private func equalsIgnoringASCIICase(_ name: String, _ lowercase: String) -> Bool {
    let bytes = Array(name.utf8)
    let expected = Array(lowercase.utf8)
    guard bytes.count == expected.count else {
        return false
    }
    return zip(bytes, expected).allSatisfy { byte, wanted in
        let folded = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        return folded == wanted
    }
}
