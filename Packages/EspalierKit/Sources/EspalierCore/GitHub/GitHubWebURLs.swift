import CryptoKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// The GitHub pages Espalier opens in the browser.
///
/// Each builder returns nil when there's nothing to open: no GitHub
/// repository, no web URL for it (a repository known only from its remote),
/// or no upstream for a branch.
public enum GitHubWebURLs {
    /// The repository's page ("View on GitHub"): the parent's page for a fork
    /// that contributes to its parent.
    public static func repository(_ record: RepositoryRecord) -> URL? {
        url(getGitHubHtmlUrl(record))
    }

    /// The branch's upstream on GitHub (`<repo>/tree/<branch>`), in the
    /// repository's own GitHub repository.
    public static func branch(_ branch: Branch, in gitHubRepository: GitHubRepository) -> URL? {
        branchView("tree", branch, gitHubRepository)
    }

    /// GitHub's comparison of the branch's upstream with the default branch
    /// (`<repo>/compare/<branch>`).
    public static func compare(_ branch: Branch, in gitHubRepository: GitHubRepository) -> URL? {
        branchView("compare", branch, gitHubRepository)
    }

    /// The commit's page, scrolled to `filePath`'s diff when given (GitHub
    /// names a file's diff by the SHA-256 of its path).
    public static func commit(_ sha: String, in gitHubRepository: GitHubRepository, filePath: String? = nil) -> URL? {
        guard let baseURL = gitHubRepository.htmlURL else {
            return nil
        }
        guard let filePath else {
            return url("\(baseURL)/commit/\(sha)")
        }
        let fileHash = SHA256.hash(data: Data(filePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return url("\(baseURL)/commit/\(sha)#diff-\(fileHash)")
    }

    /// The pull request's page, in its base repository.
    public static func pullRequest(_ pullRequest: PullRequest) -> URL? {
        self.pullRequest(number: pullRequest.pullRequestNumber, in: pullRequest.base.gitHubRepository)
    }

    /// Pull request `number` of `gitHubRepository` (`<repo>/pull/<number>`).
    public static func pullRequest(number: Int, in gitHubRepository: GitHubRepository) -> URL? {
        gitHubRepository.htmlURL.flatMap { url("\($0)/pull/\(number)") }
    }

    /// GitHub's form for a pull request from `compare` into `base`, or into
    /// the default branch when `base` is nil.
    ///
    /// The compare branch is its upstream's name when it has one. For a fork
    /// that contributes to its parent, both sides name their repository
    /// (`<parentOwner>:<parentName>:<base>...<owner>:<name>:<branch>`), so the
    /// pull request targets the parent.
    public static func createPullRequest(for record: RepositoryRecord, compare: Branch, base: Branch? = nil) -> URL? {
        guard let gitHubRepository = record.gitHubRepository, let htmlURL = gitHubRepository.htmlURL else {
            return nil
        }

        let isForkContributingToParent = isForkedRepositoryContributingToParent(record)

        var baseForkPreface = ""
        if isForkContributingToParent, let parent = gitHubRepository.parent {
            baseForkPreface = "\(parent.owner.login):\(parent.name):"
        }
        let encodedBaseBranch = base.map { baseForkPreface + JSURL.encodeURIComponent($0.nameWithoutRemote) + "..." } ?? ""

        let compareForkPreface = isForkContributingToParent
            ? "\(gitHubRepository.owner.login):\(gitHubRepository.name):"
            : ""
        let encodedCompareBranch = compareForkPreface
            + JSURL.encodeURIComponent(compare.upstreamWithoutRemote ?? compare.nameWithoutRemote)

        return url("\(htmlURL)/pull/new/\(encodedBaseBranch)\(encodedCompareBranch)")
    }

    /// GitHub's page for opening an issue, in the parent repository of a fork
    /// that contributes to it.
    public static func newIssue(_ record: RepositoryRecord) -> URL? {
        getGitHubHtmlUrl(record).flatMap { url("\($0)/issues/new/choose") }
    }

    /// Issue (or pull request) `number`'s page, for `#123` in commit
    /// messages.
    public static func issue(number: Int, in gitHubRepository: GitHubRepository) -> URL? {
        gitHubRepository.htmlURL.flatMap { url("\($0)/issues/\(number)") }
    }

    /// GitHub Explore on the repository's host: `https://github.com/explore`,
    /// or `https://<host>/explore` for an enterprise server.
    public static func explore(_ gitHubRepository: GitHubRepository) -> URL? {
        guard let htmlURL = gitHubRepository.htmlURL, var explore = try? JSURL(htmlURL) else {
            return nil
        }
        explore.pathname = "/explore"
        return url(explore.href)
    }

    /// The rulesets that apply to `branchName`
    /// (`<repo>/rules/?ref=refs%2Fheads%2F<branch>`).
    public static func rulesets(forBranch branchName: String, in gitHubRepository: GitHubRepository) -> URL? {
        gitHubRepository.htmlURL.flatMap {
            url("\($0)/rules/?ref=\(JSURL.encodeURIComponent("refs/heads/" + branchName))")
        }
    }

    /// Ruleset `id`'s page (`<repo>/rules/<id>`).
    public static func ruleset(id: Int, in gitHubRepository: GitHubRepository) -> URL? {
        gitHubRepository.htmlURL.flatMap { url("\($0)/rules/\(id)") }
    }

    /// The page where the user reviews and revokes Espalier's access to the
    /// account (signing out can't revoke the token, which needs a client
    /// secret). Nil for an account without a known OAuth app.
    public static func applicationSettings(for account: Account) -> URL? {
        account.endpointConfiguration.flatMap {
            url(getOAuthApplicationSettingsURL(endpoint: $0.endpoint, clientID: $0.clientID))
        }
    }

    // MARK: Helpers

    /// `<repo>/<view>/<encoded upstream>` for a branch with an upstream.
    private static func branchView(_ view: String, _ branch: Branch, _ gitHubRepository: GitHubRepository) -> URL? {
        guard let htmlURL = gitHubRepository.htmlURL, let upstream = branch.upstreamWithoutRemote, !upstream.isEmpty else {
            return nil
        }
        return url("\(htmlURL)/\(view)/\(JSURL.encodeURIComponent(upstream))")
    }

    private static func url(_ string: String?) -> URL? {
        string.flatMap { URL(string: $0) }
    }
}
