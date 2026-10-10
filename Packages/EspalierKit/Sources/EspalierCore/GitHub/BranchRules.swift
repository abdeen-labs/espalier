// Ported from desktop/app/src/lib/helpers/repo-rules.ts, push-control.ts, and lib/stores/helpers/find-branch-name.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "repo-rules")

// MARK: Push control

/// Determine if branch can be pushed to by user based on results from
/// push_control API.
///
/// Note: "admin-enforced" means that admins are restricted according to branch
/// protection rules. By default admins are not restricted.
///
/// `allow_actor` indicates if user is permitted
/// Always `true` for admins.
/// `true` if `Restrict who can push` is not enabled.
/// `true` if `Restrict who can push` is enabled and user is in list.
/// `false` if `Restrict who can push` is enabled and user is not in list.
///
/// `required_status_checks` indicates if checks are required for merging
/// Empty array if user is admin and branch is not admin-enforced.
///
/// `required_approving_review_count` indicates if reviews are required before merging
/// 0 if user is admin and branch is not admin-enforced
public func isBranchPushable(_ pushControl: APIPushControl) -> Bool {
    // If user is admin and branch is not admin-enforced,
    // required status checks and reviews get zeroed out in API response (no merge requirements).
    // If user is admin and branch is admin-enforced,
    // required status checks and reviews do NOT get zeroed out in API response.
    // If user is allowed to push based on `Restrict who can push` setting, they must still
    // respect the merge requirements, and can't push if checks or reviews are required for merging
    let noMergeRequirements = pushControl.requiredStatusChecks.isEmpty && pushControl.requiredApprovingReviewCount == 0

    return pushControl.allowActor && noMergeRequirements
}

// MARK: The branch name for protection

/// Function to determine which branch name to use when looking for branch
/// protection information.
///
/// If the remote branch matches the current `githubRepository` associated with
/// the repository, this will be used. Otherwise we will fall back to using the
/// branch name as that's a reasonable approximation for what would happen if the
/// user tries to push the new branch.
public func findRemoteBranchName(_ tip: Tip, _ remote: Remote?, _ gitHubRepository: GitHubRepository) -> String? {
    guard case .valid(let branch) = tip else {
        return nil
    }

    if let upstream = branch.upstreamWithoutRemote, let remote, urlMatchesCloneURL(remote.url, gitHubRepository) {
        return upstream
    }

    return branch.nameWithoutRemote
}

// MARK: Repository rules

/// Returns whether repo rules could potentially exist for the provided account and repository.
/// This only performs client-side checks, such as whether the user is on a free plan
/// and the repo is public.
public func useRepoRulesLogic(_ account: Account?, _ repository: RepositoryRecord) -> Bool {
    useRepoRulesLogic(account, repository.gitHubRepository)
}

/// `useRepoRulesLogic` for a repository's GitHub repository.
func useRepoRulesLogic(_ account: Account?, _ gitHubRepository: GitHubRepository?, runtime: GitHubRuntime = .current) -> Bool {
    guard let account, let gitHubRepository else {
        return false
    }

    if !supportsRepoRules(gitHubRepository.endpoint, runtime: runtime) {
        return false
    }

    // repo owner's plan can't be checked, only the current user's. purposely return true
    // if the repo owner is someone else, because if the current user is a collaborator on
    // the free plan but the owner is a pro member, then repo rules could still be enabled.
    // errors will be thrown by the API in this case, but there's no way to preemptively
    // check for that.
    if JSCompat.strictEquals(account.login, gitHubRepository.owner.login),
       account.plan == nil || account.plan == "free",
       gitHubRepository.isPrivate == true {
        return false
    }

    return true
}

/// Parses the GitHub API response for a branch's repo rules into a more useable
/// format.
///
/// - Parameter gpgSignEnabled: Whether the repository's git config signs
///   commits (`commit.gpgsign`); asked only for a signed-commits rule.
public func parseRepoRules(
    _ rules: [APIRepoRule],
    _ rulesets: [Int: APIRepoRuleset],
    gpgSignEnabled: () async -> Bool
) async -> RepoRulesInfo {
    var info = RepoRulesInfo()
    var gpgSign: Bool?

    for rule in rules {
        // if a ruleset is null/undefined, then act as if the rule doesn't exist because
        // we don't know what will happen when they push
        guard let ruleset = rulesets[rule.rulesetID] else {
            continue
        }

        // a rule may be configured multiple times, and the strictest value always applies.
        // since the rule will not exist in the API response if it's not enforced, we know
        // we're always assigning either 'bypass' or true below. therefore, we only need
        // to check if the existing value is true, otherwise it can always be overridden.
        let enforced: RepoRuleEnforced = ruleset.currentUserCanBypass == .always ? .bypass : .enforced

        switch rule.type {
        case .update, .requiredDeployments, .requiredStatusChecks:
            info.basicCommitWarning = strictest(info.basicCommitWarning, enforced)

        case .creation:
            info.creationRestricted = strictest(info.creationRestricted, enforced)

        case .requiredSignatures:
            // check if the user has commit signing configured. if they do, the rule
            // passes and doesn't need to be warned about.
            if gpgSign == nil {
                gpgSign = await gpgSignEnabled()
            }
            if gpgSign != true {
                info.signedCommitsRequired = strictest(info.signedCommitsRequired, enforced)
            }

        case .pullRequest:
            info.pullRequestRequired = strictest(info.pullRequestRequired, enforced)

        case .commitMessagePattern:
            info.commitMessagePatterns.push(toMetadataRule(rule, enforced))

        case .commitAuthorEmailPattern:
            info.commitAuthorEmailPatterns.push(toMetadataRule(rule, enforced))

        case .committerEmailPattern:
            info.committerEmailPatterns.push(toMetadataRule(rule, enforced))

        case .branchNamePattern:
            info.branchNamePatterns.push(toMetadataRule(rule, enforced))

        default:
            break
        }
    }

    return info
}

/// Parses the rules as `parseRepoRules(_:_:gpgSignEnabled:)`, reading
/// `commit.gpgsign` from `repository`'s git config when needed.
public func parseRepoRules(_ rules: [APIRepoRule], _ rulesets: [Int: APIRepoRuleset], repository: Repository) async -> RepoRulesInfo {
    await parseRepoRules(rules, rulesets) {
        ((try? await getBooleanConfigValue(repository, "commit.gpgsign")) ?? nil) ?? false
    }
}

/// `true` stays; otherwise the new value applies.
private func strictest(_ existing: RepoRuleEnforced, _ new: RepoRuleEnforced) -> RepoRuleEnforced {
    existing == .enforced ? .enforced : new
}

private func toMetadataRule(_ rule: APIRepoRule, _ enforced: RepoRuleEnforced) -> RepoRulesMetadataRule? {
    guard let parameters = rule.parameters else {
        return nil
    }

    return RepoRulesMetadataRule(
        enforced: enforced,
        matcher: toMatcher(parameters),
        humanDescription: toHumanDescription(parameters),
        rulesetId: rule.rulesetID
    )
}

private func toHumanDescription(_ apiParams: APIRepoRuleMetadataParameters) -> String {
    var description = "must "
    if apiParams.negate {
        description += "not "
    }

    if apiParams.operator == .regexMatch {
        return description + "match the regular expression \"\(apiParams.pattern)\""
    }

    switch apiParams.operator {
    case .startsWith:
        description += "start with "
    case .endsWith:
        description += "end with "
    case .contains:
        description += "contain "
    default:
        break
    }

    return description + "\"\(apiParams.pattern)\""
}

/// Converts the given metadata rule into a matcher function that uses regex
/// to test the rule.
///
/// GitHub evaluates the patterns with RE2; they're translated to ICU
/// (`translateRE2Pattern`). A pattern ICU can't compile counts as passing
/// (and is logged): GitHub accepted it, so failing the user's commit on the
/// translation would be wrong.
private func toMatcher(_ rule: APIRepoRuleMetadataParameters) -> RepoRulesMetadataMatcher {
    let pattern: String
    switch rule.operator {
    case .startsWith:
        pattern = "^" + NSRegularExpression.escapedPattern(for: rule.pattern)
    case .endsWith:
        // RE2's `$` is the end of the text.
        pattern = NSRegularExpression.escapedPattern(for: rule.pattern) + "\\z"
    case .contains:
        pattern = ".*" + NSRegularExpression.escapedPattern(for: rule.pattern) + ".*"
    case .regexMatch:
        pattern = translateRE2Pattern(rule.pattern)
    default:
        return { _ in false }
    }

    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        logger.error("Could not use the rule pattern \(rule.pattern, privacy: .public)")
        return { _ in true }
    }
    let box = RegexBox(regex)
    if rule.negate {
        return { toMatch in !box.test(toMatch) }
    } else {
        return { toMatch in box.test(toMatch) }
    }
}

/// A compiled regular expression, which is immutable and safe to share.
private final class RegexBox: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ regex: NSRegularExpression) {
        self.regex = regex
    }

    /// Whether the pattern matches anywhere in `string`.
    func test(_ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..<string.endIndex, in: string)) != nil
    }
}

/// Translates an RE2 pattern (the syntax GitHub's rules use) to ICU's where
/// the two match differently:
///
/// - `$` outside a character class is the end of the text in RE2 (ICU's
///   also matches before a final line break), unless multi-line mode (`m`)
///   is on somewhere in the pattern.
/// - `.` doesn't match `\n` only in RE2 (ICU's also refuses `\r`, U+0085,
///   U+2028, and U+2029), unless `s` is on somewhere in the pattern.
/// - `\d`, `\s`, and `\w` (and their negations) are ASCII in RE2, Unicode in
///   ICU.
/// - RE2's `(?P<name>...)` is ICU's `(?<name>...)`.
///
/// Flags set in the middle of a pattern apply to all of it here: patterns
/// that mix modes are rare enough not to justify a full parser.
func translateRE2Pattern(_ pattern: String) -> String {
    let scalars = Array(pattern.unicodeScalars)
    let flags = inlineFlags(scalars)
    let multiLine = flags.contains("m")
    let dotAll = flags.contains("s")

    var out = String.UnicodeScalarView()
    func append(_ string: String) {
        out.append(contentsOf: string.unicodeScalars)
    }

    var index = 0
    var inClass = false
    var classStart = 0
    while index < scalars.count {
        let scalar = scalars[index]

        if scalar == "\\" {
            guard index + 1 < scalars.count else {
                append("\\\\")
                break
            }
            let next = scalars[index + 1]
            if next == "Q" {
                // \Q...\E quotes literally, in RE2 and ICU alike.
                var end = index + 2
                while end < scalars.count, !(scalars[end] == "\\" && end + 1 < scalars.count && scalars[end + 1] == "E") {
                    end += 1
                }
                let stop = min(end + 2, scalars.count)
                out.append(contentsOf: scalars[index..<stop])
                index = stop
                continue
            }
            switch (inClass, next) {
            case (false, "d"): append("[0-9]")
            case (false, "D"): append("[^0-9]")
            case (false, "s"): append("[\\t\\n\\f\\r ]")
            case (false, "S"): append("[^\\t\\n\\f\\r ]")
            case (false, "w"): append("[0-9A-Za-z_]")
            case (false, "W"): append("[^0-9A-Za-z_]")
            case (true, "d"): append("0-9")
            case (true, "s"): append("\\t\\n\\f\\r ")
            case (true, "w"): append("0-9A-Za-z_")
            default:
                out.append(scalar)
                out.append(next)
            }
            index += 2
            continue
        }

        if inClass {
            if scalar == "[", index + 1 < scalars.count, scalars[index + 1] == ":" {
                // A POSIX class, [:alpha:].
                var end = index + 2
                while end + 1 < scalars.count, !(scalars[end] == ":" && scalars[end + 1] == "]") {
                    end += 1
                }
                let stop = min(end + 2, scalars.count)
                out.append(contentsOf: scalars[index..<stop])
                index = stop
                continue
            }
            // A `]` first in the class (after `[` or `[^`) is literal.
            if scalar == "]", index > classStart {
                inClass = false
            }
            out.append(scalar)
            index += 1
            continue
        }

        switch scalar {
        case "[":
            inClass = true
            out.append(scalar)
            index += 1
            if index < scalars.count, scalars[index] == "^" {
                out.append(scalars[index])
                index += 1
            }
            classStart = index
            continue
        case "$" where !multiLine:
            append("\\z")
        case "." where !dotAll:
            append("[^\\n]")
        case "(" where index + 3 < scalars.count && scalars[index + 1] == "?" && scalars[index + 2] == "P" && scalars[index + 3] == "<":
            append("(?<")
            index += 4
            continue
        default:
            out.append(scalar)
        }
        index += 1
    }

    return String(out)
}

/// The flags the pattern turns on anywhere, in `(?flags)` or
/// `(?flags:...)` groups (flags after a `-` turn off and don't count).
private func inlineFlags(_ scalars: [Unicode.Scalar]) -> Set<Unicode.Scalar> {
    var flags: Set<Unicode.Scalar> = []
    var index = 0
    var inClass = false
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\\" {
            index += 2
            continue
        }
        if inClass {
            if scalar == "]" {
                inClass = false
            }
            index += 1
            continue
        }
        if scalar == "[" {
            inClass = true
            index += 1
            if index < scalars.count, scalars[index] == "^" {
                index += 1
            }
            // A leading `]` is literal.
            if index < scalars.count, scalars[index] == "]" {
                index += 1
            }
            continue
        }
        if scalar == "(", index + 1 < scalars.count, scalars[index + 1] == "?" {
            var cursor = index + 2
            var turningOff = false
            var group: Set<Unicode.Scalar> = []
            var isFlagGroup = true
            while cursor < scalars.count, scalars[cursor] != ")", scalars[cursor] != ":" {
                let flag = scalars[cursor]
                if flag == "-" {
                    turningOff = true
                } else if "imsU".unicodeScalars.contains(flag) {
                    if !turningOff {
                        group.insert(flag)
                    }
                } else {
                    isFlagGroup = false
                    break
                }
                cursor += 1
            }
            if isFlagGroup {
                flags.formUnion(group)
            }
        }
        index += 1
    }
    return flags
}

/// Returns the human-readable descriptions of all rules that the server will
/// evaluate when the user pushes the commit. This includes rules the current
/// user is permitted to bypass (since the server still evaluates them) but
/// excludes rules that are not enforced for the current user.
public func getEnforcedRuleDescriptions(_ rules: [RepoRulesMetadataRule]) -> [String] {
    rules.filter { $0.enforced == .enforced || $0.enforced == .bypass }.map(\.humanDescription)
}

// MARK: Rule failures as the composer and the branch sheets show them

extension RepoRulesMetadataFailures {
    /// The failure list's sentence: "<leading text> fails 2 rules." or "...,
    /// but you can bypass them." Nil when every rule passes.
    ///
    /// - Parameter leadingText: What was checked: "This commit message", or
    ///   "Your commit email, <email>,".
    public func summary(leadingText: String) -> String? {
        guard status != .pass else {
            return nil
        }
        let totalFails = failed.count + bypassed.count
        let endText: String
        if status == .bypass {
            endText = ", but you can bypass \(totalFails == 1 ? "it" : "them")."
        } else {
            endText = "."
        }
        return "\(leadingText) fails \(totalFails) rule\(totalFails > 1 ? "s" : "")\(endText)"
    }
}

/// A branch name the repository's rules restrict, for the New Branch and
/// Rename Branch sheets.
public struct BranchNameRuleError: Sendable, Equatable {
    /// "Repository rules don't allow a branch named “fix”." or "Repository
    /// rules restrict a branch named “fix”, but you can bypass them."
    public let message: String
    /// Whether the user can bypass the rules: a warning, not an error.
    public let isWarning: Bool

    public init(message: String, isWarning: Bool) {
        self.message = message
        self.isWarning = isWarning
    }
}

/// The branch name check of `checkBranchNameRules` over parsed rules.
///
/// It decides from the rules that fail, not from every ruleset that
/// applies: one the user can't bypass is an error, else one the user can
/// bypass is a warning.
func branchNameRuleError(_ branchName: String, _ info: RepoRulesInfo) -> BranchNameRuleError? {
    let status = info.branchNamePatterns.getFailedRules(branchName).status
    let quoted = "\u{201C}\(branchName)\u{201D}"
    if info.creationRestricted == .enforced || status == .fail {
        return BranchNameRuleError(message: "Repository rules don't allow a branch named \(quoted).", isWarning: false)
    }
    if info.creationRestricted == .bypass || status == .bypass {
        return BranchNameRuleError(
            message: "Repository rules restrict a branch named \(quoted), but you can bypass them.",
            isWarning: true
        )
    }
    return nil
}

/// The warning the commit message composer shows about the current branch,
/// one at a time in priority order: no write access, a protected branch, then
/// repository rules (publishing, signed commits, pushing), those that will stop
/// the user before those they can bypass.
public enum CommitRuleWarning: Sendable, Equatable {
    /// What the composer offers with a warning.
    public enum Action: Sendable, Equatable {
        /// Fork the repository (`sync.createFork()`).
        case createFork
        /// Show the branches, to switch to another.
        case switchBranches
    }

    /// The user can't push to the repository.
    case noWriteAccess(repositoryName: String)
    /// The branch's protection stops the user's pushes.
    case branchProtected(branch: String)
    /// The branch's name or its creation is restricted: it can't be
    /// published.
    case publishRestricted(branch: String, canBypass: Bool)
    /// Rules require signed commits and the repository doesn't sign them.
    case signedCommitsRequired(branch: String, canBypass: Bool)
    /// Rules restrict pushing to the branch: updates, required status
    /// checks or deployments, or a required pull request.
    case pushRestricted(branch: String, canBypass: Bool)

    /// Whether the warning is an error (the commit can't be pushed and the
    /// commit button is disabled) rather than a caution.
    public var isError: Bool {
        switch self {
        case .noWriteAccess, .branchProtected:
            false
        case .publishRestricted(_, let canBypass), .signedCommitsRequired(_, let canBypass), .pushRestricted(_, let canBypass):
            !canBypass
        }
    }

    /// The warning. The UI can link "Repository rules" to the branch's
    /// rulesets (`GitHubWebURLs.rulesets(forBranch:in:)`) and offer
    /// `action`.
    public var message: String {
        switch self {
        case .noWriteAccess(let repositoryName):
            return "You don't have write access to \(repositoryName)."
        case .branchProtected(let branch):
            return "\(branch) is a protected branch."
        case .publishRestricted(let branch, let canBypass):
            return canBypass
                ? "Repository rules restrict publishing \(branch), but you can bypass them."
                : "Repository rules don't allow publishing \(branch)."
        case .signedCommitsRequired(let branch, let canBypass):
            return canBypass
                ? "Repository rules require signed commits on \(branch), but you can bypass them."
                : "Repository rules require signed commits on \(branch)."
        case .pushRestricted(let branch, let canBypass):
            return canBypass
                ? "Repository rules restrict pushing to \(branch), but you can bypass them."
                : "Repository rules don't allow pushing to \(branch)."
        }
    }

    /// What the composer offers with the warning, or nil.
    public var action: Action? {
        switch self {
        case .noWriteAccess:
            .createFork
        case .branchProtected:
            .switchBranches
        case .publishRestricted(_, let canBypass), .pushRestricted(_, let canBypass):
            canBypass ? nil : .switchBranches
        case .signedCommitsRequired:
            nil
        }
    }
}

/// What the composer's rule checks look at.
struct CommitRuleInputs {
    var gitHubRepository: GitHubRepository?
    /// Whether rules can apply (`useRepoRulesLogic`).
    var rulesEnabled: Bool
    var rules: RepoRulesInfo
    var currentBranchProtected: Bool
    /// The current branch's name, nil on a detached HEAD.
    var branch: String?
    /// Nil when the branch has no upstream: it's unpublished.
    var aheadBehind: AheadBehind?
    /// The number of changed files.
    var fileCount: Int
}

/// The composer's warning about the current branch, as data.
///
/// A required pull request (`pull_request` rule) counts with the rules that
/// prevent pushing, so the disabled commit button comes with a reason.
func commitRuleWarning(_ inputs: CommitRuleInputs) -> CommitRuleWarning? {
    if let gitHubRepository = inputs.gitHubRepository, inputs.fileCount > 0, !hasWritePermission(gitHubRepository) {
        return .noWriteAccess(repositoryName: gitHubRepository.name)
    }
    if inputs.fileCount > 0, inputs.currentBranchProtected {
        // If the branch is null that means we haven't loaded the tip yet or
        // we're on a detached head.
        return inputs.branch.map { .branchProtected(branch: $0) }
    }
    guard inputs.rulesEnabled, let branch = inputs.branch else {
        return nil
    }

    var statuses: [(kind: Int, enforced: RepoRuleEnforced)] = []
    // has the current branch has been published?
    if inputs.aheadBehind == nil {
        let nameStatus = inputs.rules.branchNamePatterns.getFailedRules(branch).status
        if inputs.rules.creationRestricted == .enforced || nameStatus == .fail {
            statuses.append((0, .enforced))
        } else if inputs.rules.creationRestricted == .bypass || nameStatus == .bypass {
            statuses.append((0, .bypass))
        }
    }
    statuses.append((1, inputs.rules.signedCommitsRequired))
    statuses.append((2, strictestOf(inputs.rules.basicCommitWarning, inputs.rules.pullRequestRequired)))

    // grab the first error to display, else the first bypassed
    let chosen = statuses.first { $0.enforced == .enforced } ?? statuses.first { $0.enforced == .bypass }
    guard let chosen else {
        return nil
    }
    let canBypass = chosen.enforced == .bypass
    switch chosen.kind {
    case 0: return .publishRestricted(branch: branch, canBypass: canBypass)
    case 1: return .signedCommitsRequired(branch: branch, canBypass: canBypass)
    default: return .pushRestricted(branch: branch, canBypass: canBypass)
    }
}

private func strictestOf(_ x: RepoRuleEnforced, _ y: RepoRuleEnforced) -> RepoRuleEnforced {
    if x == .enforced || y == .enforced {
        return .enforced
    }
    if x == .bypass || y == .bypass {
        return .bypass
    }
    return .notEnforced
}

/// Why the rules stop a commit (the commit button is disabled), or nil,
/// with the composer's copy.
///
/// - Parameters:
///   - message: The commit message as it would be committed
///     (`formatCommitMessage`).
///   - authorEmail: The commit author's email, if known.
func repoRuleCommitFailure(_ inputs: CommitRuleInputs, message: String, authorEmail: String?) -> String? {
    guard inputs.rulesEnabled else {
        return nil
    }
    let rules = inputs.rules
    let branch = inputs.branch ?? ""

    if rules.basicCommitWarning == .enforced || rules.pullRequestRequired == .enforced {
        return CommitRuleWarning.pushRestricted(branch: branch, canBypass: false).message
    }
    if rules.signedCommitsRequired == .enforced {
        return CommitRuleWarning.signedCommitsRequired(branch: branch, canBypass: false).message
    }
    let messageFailures = rules.commitMessagePatterns.getFailedRules(message)
    if messageFailures.status == .fail, let summary = messageFailures.summary(leadingText: "This commit message") {
        return summary
    }
    if let authorEmail {
        let authorFailures = rules.commitAuthorEmailPatterns.getFailedRules(authorEmail)
        if authorFailures.status == .fail,
           let summary = authorFailures.summary(leadingText: "Your commit email, \(authorEmail),") {
            return summary
        }
    }
    if inputs.aheadBehind == nil {
        let nameStatus = rules.branchNamePatterns.getFailedRules(branch).status
        if rules.creationRestricted == .enforced || nameStatus == .fail {
            return CommitRuleWarning.publishRestricted(branch: branch, canBypass: false).message
        }
    }
    return nil
}

// MARK: The repository's protection and rules

extension RepositoryGitHubModel {
    /// The account for the repository's GitHub repository, if signed in.
    var account: Account? {
        guard let repository, let app = repository.app else {
            return nil
        }
        return app.accounts.account(for: repository.record)
    }

    /// Whether rules can apply to this repository for the signed-in account
    /// (`useRepoRulesLogic`).
    public var repoRulesEnabled: Bool {
        guard let repository else {
            return false
        }
        return useRepoRulesLogic(account, repository.record.gitHubRepository, runtime: repository.environment.gitHub)
    }

    /// Loads whether the current branch is protected and which rules apply
    /// to it.
    ///
    /// Needs a branch, a GitHub repository, and an account for it; without
    /// write access the branch counts as unprotected, without asking (the
    /// composer warns about write access instead). A failed push control
    /// check counts as unprotected; rules that can't be loaded count as
    /// none. A refresh that finishes after another started, after
    /// `clearBranchProtection()`, or after the branch changed is dropped.
    public func refreshBranchProtection() async {
        guard let repository, let app = repository.app else {
            return
        }
        // Called after each association: a new GitHub repository brings
        // its own pull requests.
        if syncGitHubRepository() {
            gitHubRepositoryDidChange()
        }
        let tip = repository.gitState.tip
        guard case .valid = tip, let gitHubRepository = repository.record.gitHubRepository else {
            return
        }
        guard let branchName = findRemoteBranchName(tip, repository.gitState.remotes.currentRemote, gitHubRepository),
              let account = app.accounts.account(for: repository.record)
        else {
            return
        }

        protectionGeneration &+= 1
        let generation = protectionGeneration
        let tipBranch = tip.branch?.name

        await track {
            let state = await self.loadBranchProtection(branchName, gitHubRepository: gitHubRepository, account: account)
            guard generation == self.protectionGeneration,
                  let current = self.repository?.gitState.tip.branch?.name,
                  tipBranch.map({ JSCompat.strictEquals($0, current) }) == true
            else {
                return
            }
            if self.currentBranchProtected != state.protected {
                self.currentBranchProtected = state.protected
            }
            self.repoRules = state.rules
        }
    }

    private func loadBranchProtection(
        _ branchName: String,
        gitHubRepository: GitHubRepository,
        account: Account
    ) async -> (protected: Bool, rules: RepoRulesInfo) {
        guard let repository else {
            return (false, RepoRulesInfo())
        }

        // If the user doesn't have write access to the repository
        // it doesn't matter if the branch is protected or not and
        // we can avoid the API call. See the `noWriteAccess` warning,
        // which the composer shows before a branch protection warning.
        if !hasWritePermission(gitHubRepository) {
            return (false, RepoRulesInfo())
        }

        let environment = repository.environment
        let gitRepository = repository.gitRepository
        let name = gitHubRepository.name
        let owner = gitHubRepository.owner.login
        let api = API.fromAccount(account, runtime: environment.gitHub)

        let pushControl = await api.fetchPushControl(owner: owner, name: name, branch: branchName)
        let currentBranchProtected = !isBranchPushable(pushControl)

        var rules = RepoRulesInfo()
        if useRepoRulesLogic(account, gitHubRepository, runtime: environment.gitHub) {
            await cacheRulesets(api, owner: owner, name: name)
            let branchRules = await api.fetchRepoRulesForBranch(owner: owner, name: name, branch: branchName)
            if !branchRules.isEmpty {
                let rulesets = cachedRepoRulesets
                rules = await environment.withRuntimes {
                    await parseRepoRules(branchRules, rulesets, repository: gitRepository)
                }
            }
        }
        return (currentBranchProtected, rules)
    }

    /// Fetches the repository's rulesets that aren't cached yet, so they're
    /// at hand when rules are evaluated. The cache is per repository, never
    /// invalidated in a session.
    private func cacheRulesets(_ api: API, owner: String, name: String) async {
        // ultimate goal here is to fetch all rulesets that apply to the repo
        // so they're already cached when needed later on
        guard let slimRulesets = await api.fetchAllRepoRulesets(owner: owner, name: name), !slimRulesets.isEmpty else {
            return
        }
        for id in slimRulesets.map(\.id) where cachedRepoRulesets[id] == nil {
            // check the cache and don't re-query any that are already in there
            if let ruleset = await api.fetchRepoRuleset(owner: owner, name: name, id: id) {
                cachedRepoRulesets[ruleset.id] = ruleset
            }
        }
    }

    /// Whether `branchName` may be used for a new branch or a rename, by the
    /// repository's rules. Nil when it may, or when rules can't be checked (not
    /// on GitHub, no account, rules not available).
    public func checkBranchNameRules(_ branchName: String) async -> BranchNameRuleError? {
        guard let repository, !branchName.isEmpty, let gitHubRepository = repository.record.gitHubRepository,
              let account, useRepoRulesLogic(account, gitHubRepository, runtime: repository.environment.gitHub)
        else {
            return nil
        }

        let environment = repository.environment
        let api = API.fromAccount(account, runtime: environment.gitHub)
        let owner = gitHubRepository.owner.login
        let name = gitHubRepository.name
        let branchRules = await api.fetchRepoRulesForBranch(owner: owner, name: name, branch: branchName)

        // filter the rules to only the relevant ones
        let relevant = branchRules.filter { $0.type == .creation || $0.type == .branchNamePattern }

        // there are no relevant rules for this branch name
        if relevant.isEmpty {
            return nil
        }

        if relevant.contains(where: { cachedRepoRulesets[$0.rulesetID] == nil }) {
            await cacheRulesets(api, owner: owner, name: name)
        }

        // check for actual failures
        let rulesets = cachedRepoRulesets
        let gitRepository = repository.gitRepository
        let info = await environment.withRuntimes {
            await parseRepoRules(relevant, rulesets, repository: gitRepository)
        }
        return branchNameRuleError(branchName, info)
    }

    /// The composer's warning about the current branch, in priority order,
    /// or nil.
    public var commitWarning: CommitRuleWarning? {
        guard let repository else {
            return nil
        }
        return commitRuleWarning(commitRuleInputs(repository))
    }

    /// The rules the commit message fails, for the composer's "Commit
    /// Message Rule Failures" popover; every rule passes when rules don't
    /// apply. The message is formatted as it will be committed.
    public func commitMessageRuleFailures() async -> RepoRulesMetadataFailures {
        guard let repository, repoRulesEnabled, let rules = repoRules, rules.commitMessagePatterns.hasRules else {
            return RepoRulesMetadataFailures()
        }
        let message = await ruleCheckedCommitMessage(repository)
        return rules.commitMessagePatterns.getFailedRules(message)
    }

    /// The rules the commit author's email fails, for the composer's author
    /// popover.
    public var commitAuthorRuleFailures: RepoRulesMetadataFailures {
        guard let repository, repoRulesEnabled, let rules = repoRules,
              let email = repository.gitState.commitAuthor?.email
        else {
            return RepoRulesMetadataFailures()
        }
        return rules.commitAuthorEmailPatterns.getFailedRules(email)
    }

    /// The commit message rules, for generating a message that follows them:
    /// every rule enforced for the user or that they can bypass, which GitHub
    /// still evaluates.
    public var commitMessageRules: [RepoRulesMetadataRule] {
        guard repoRulesEnabled, let rules = repoRules else {
            return []
        }
        return rules.commitMessagePatterns.getRules()
    }

    /// Why the repository's rules stop the commit, or nil (the commit gate).
    func repoRuleCommitFailure() async -> String? {
        guard let repository, repoRulesEnabled, repoRules != nil else {
            return nil
        }
        let message = await ruleCheckedCommitMessage(repository)
        // The rules may have changed meanwhile; check the current ones.
        guard repoRulesEnabled else {
            return nil
        }
        return EspalierCore.repoRuleCommitFailure(
            commitRuleInputs(repository),
            message: message,
            authorEmail: repository.gitState.commitAuthor?.email
        )
    }

    private func commitRuleInputs(_ repository: RepositoryModel) -> CommitRuleInputs {
        CommitRuleInputs(
            gitHubRepository: repository.record.gitHubRepository,
            rulesEnabled: repoRulesEnabled,
            rules: repoRules ?? RepoRulesInfo(),
            currentBranchProtected: currentBranchProtected,
            branch: repository.gitState.tip.branch?.name,
            aheadBehind: repository.gitState.aheadBehind,
            fileCount: repository.changes.workingDirectory.files.count
        )
    }

    /// The draft as the commit would format it: the summary, or the
    /// single-file placeholder when both the summary and the description are
    /// empty; the description; the co-author trailers; amend mode.
    private func ruleCheckedCommitMessage(_ repository: RepositoryModel) async -> String {
        let commit = repository.commit
        let draft = commit.draft
        var summary = draft.summary
        if summary.isEmpty, draft.description.isEmpty {
            summary = commit.summaryPlaceholder ?? summary
        }
        var trailers: [Trailer] = []
        if draft.showCoAuthoredBy, repository.record.gitHubRepository != nil {
            trailers = draft.coAuthors.compactMap { author in
                if case .known(let known) = author {
                    Trailer(token: "Co-Authored-By", value: "\(known.name) <\(known.email)>")
                } else {
                    nil
                }
            }
        }
        let context = CommitContext(summary: summary, description: draft.description, amend: commit.amending != nil, trailers: trailers)
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        do {
            return try await environment.withRuntimes {
                try await formatCommitMessage(gitRepository, context)
            }
        } catch {
            // Without git's trailers the message is still mostly right.
            logger.info("Could not format the commit message for the rules: \(String(describing: error), privacy: .public)")
            return "\(summary)\n\n\(draft.description)\n"
        }
    }
}
