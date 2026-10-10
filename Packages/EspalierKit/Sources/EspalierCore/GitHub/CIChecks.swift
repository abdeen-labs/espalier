// Ported from desktop/app/src/lib/ci-checks/ci-checks.ts, lib/format-duration.ts, and lib/to_sentence.ts

import EspalierSupport
import Foundation
import GitHubKit

/// An Espalier model closely related to a GitHub API Check Run.
///
/// The RefCheck object abstracts the difference between the legacy
/// Commit Status objects and the modern Check Runs and unifies them
/// under one common interface. Since all commit statuses can be
/// represented as Check Runs but not all Check Runs can be represented
/// as statuses the model closely aligns with Check Runs.
public struct RefCheck: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String
    public var status: APICheckStatus
    public var conclusion: APICheckConclusion?
    public let appName: String
    public var htmlURL: String?

    // Following are action check specific
    public let checkSuiteID: Int?
    public var actionJobSteps: [APIWorkflowJobStep]?
    public var actionsWorkflow: APIWorkflowRun?

    public init(
        id: Int,
        name: String,
        description: String,
        status: APICheckStatus,
        conclusion: APICheckConclusion?,
        appName: String,
        htmlURL: String?,
        checkSuiteID: Int?,
        actionJobSteps: [APIWorkflowJobStep]? = nil,
        actionsWorkflow: APIWorkflowRun? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.conclusion = conclusion
        self.appName = appName
        self.htmlURL = htmlURL
        self.checkSuiteID = checkSuiteID
        self.actionJobSteps = actionJobSteps
        self.actionsWorkflow = actionsWorkflow
    }
}

/// A combined view of all legacy commit statuses as well as
/// check runs for a particular Git reference.
public struct CombinedRefCheck: Sendable, Hashable {
    public let status: APICheckStatus
    public let conclusion: APICheckConclusion?
    public let checks: [RefCheck]

    public init(status: APICheckStatus, conclusion: APICheckConclusion?, checks: [RefCheck]) {
        self.status = status
        self.conclusion = conclusion
        self.checks = checks
    }
}

/// Convert a legacy API commit status to a fake check run
public func apiStatusToRefCheck(_ apiStatus: APIRefStatusItem) -> RefCheck {
    let state: APICheckStatus
    var conclusion: APICheckConclusion?

    if apiStatus.state == .success {
        state = .completed
        conclusion = .success
    } else if apiStatus.state == .pending {
        state = .inProgress
    } else {
        state = .completed
        conclusion = .failure
    }

    return RefCheck(
        id: apiStatus.id,
        name: apiStatus.context,
        description: getCheckRunShortDescription(state, conclusion),
        status: state,
        conclusion: conclusion,
        appName: "",
        htmlURL: apiStatus.targetURL,
        checkSuiteID: nil
    )
}

/// Returns the user-facing adjective for a given check run conclusion.
public func getCheckRunConclusionAdjective(_ conclusion: APICheckConclusion?) -> String {
    guard let conclusion else {
        return "In progress"
    }

    switch conclusion {
    case .actionRequired: return "Action required"
    case .canceled: return "Canceled"
    case .timedOut: return "Timed out"
    case .failure: return "Failed"
    case .neutral: return "Neutral"
    case .success: return "Successful"
    case .skipped: return "Skipped"
    case .stale: return "Marked as stale"
    default:
        // Any other conclusion: its own name, as the API spells it.
        return conclusion.rawValue
    }
}

/// Method to generate a user friendly short check run description such as
/// "Successful in xs", "In Progress", "Failed after 1m"
///
/// If the duration is not provided, it will omit the preposition and duration
/// context. Also, conclusions such as `Skipped`, 'Action required`, `Marked as
/// stale` don't make sense with duration context so it is ommited.
///
/// - Parameters:
///   - status: The overall check status, something like completed, pending,
///     or failing...
///   - conclusion: The conclusion of the check, something like success or
///     skipped...
///   - durationMs: The time in milliseconds it took to complete.
func getCheckRunShortDescription(_ status: APICheckStatus, _ conclusion: APICheckConclusion?, _ durationMs: Double? = nil) -> String {
    guard status == .completed, let conclusion else {
        return "In progress"
    }

    let adjective = getCheckRunConclusionAdjective(conclusion)

    // Some conclusions such as 'Action required' or 'Skipped' don't make sense
    // with time context so we just return them.
    if [APICheckConclusion.actionRequired, .skipped, .stale].contains(conclusion) {
        return adjective
    }

    let preposition = conclusion == .success ? "in" : "after"

    if let durationMs, durationMs > 0 {
        return "\(adjective) \(preposition) \(formatPreciseDuration(durationMs))"
    }

    return adjective
}

/// Attempts to get the duration of a check run in milliseconds. Returns nil
/// when either completed_at or started_at is missing or can't be parsed.
public func getCheckDurationInMilliseconds(completedAt: String?, startedAt: String?) -> Double? {
    guard let completedAt, let startedAt,
          let completed = parseGitHubTimestamp(completedAt),
          let started = parseGitHubTimestamp(startedAt)
    else {
        return nil
    }
    return (completed.timeIntervalSince1970 - started.timeIntervalSince1970) * 1000
}

/// Convert an API check run object to a RefCheck model
public func apiCheckRunToRefCheck(_ checkRun: APIRefCheckRun) -> RefCheck {
    RefCheck(
        id: checkRun.id,
        name: checkRun.name,
        description: getCheckRunShortDescription(
            checkRun.status,
            checkRun.conclusion,
            getCheckDurationInMilliseconds(completedAt: checkRun.completedAt, startedAt: checkRun.startedAt)
        ),
        status: checkRun.status,
        conclusion: checkRun.conclusion,
        appName: checkRun.app?.name ?? "",
        htmlURL: checkRun.htmlURL,
        checkSuiteID: checkRun.checkSuite?.id
    )
}

/// Combines a list of check runs into a single combined check with global status
/// and conclusion.
public func createCombinedCheckFromChecks(_ checks: [RefCheck]) -> CombinedRefCheck? {
    if checks.isEmpty {
        // This case is distinct from when we fail to call the API in
        // that this means there are no checks or statuses so we should
        // clear whatever info we've got for this ref.
        return nil
    }

    if checks.count == 1 {
        // If we've got exactly one check then we can mirror its status
        // and conclusion 1-1 without having to create an aggregate status
        return CombinedRefCheck(status: checks[0].status, conclusion: checks[0].conclusion, checks: checks)
    }

    if checks.contains(where: isIncompleteOrFailure) {
        return CombinedRefCheck(status: .completed, conclusion: .failure, checks: checks)
    } else if checks.allSatisfy(isSuccess) {
        return CombinedRefCheck(status: .completed, conclusion: .success, checks: checks)
    } else {
        return CombinedRefCheck(status: .inProgress, conclusion: nil, checks: checks)
    }
}

/// Whether the check is either incomplete or has failed
public func isIncompleteOrFailure(_ check: RefCheck) -> Bool {
    isIncomplete(check) || isFailure(check)
}

/// Whether the check is incomplete (timed out, stale or cancelled).
///
/// The terminology here is confusing and deserves explanation. An
/// incomplete check is a check run that has been started and who's
/// state is 'completed' but it never got to produce a conclusion
/// because it was either cancelled, it timed out, or GitHub marked
/// it as stale.
public func isIncomplete(_ check: RefCheck) -> Bool {
    guard check.status == .completed, let conclusion = check.conclusion else {
        return false
    }
    return [APICheckConclusion.timedOut, .stale, .canceled].contains(conclusion)
}

/// Whether the check has failed (failure or requires action)
public func isFailure(_ check: RefCheck) -> Bool {
    isFailure(status: check.status, conclusion: check.conclusion)
}

/// Whether the job step has failed (failure or requires action)
public func isFailure(_ step: APIWorkflowJobStep) -> Bool {
    isFailure(status: step.status, conclusion: step.conclusion)
}

private func isFailure(status: APICheckStatus, conclusion: APICheckConclusion?) -> Bool {
    guard status == .completed, let conclusion else {
        return false
    }
    return conclusion == .failure || conclusion == .actionRequired
}

/// Whether the check can be considered successful (success, neutral or skipped)
public func isSuccess(_ check: RefCheck) -> Bool {
    guard check.status == .completed, let conclusion = check.conclusion else {
        return false
    }
    return [APICheckConclusion.success, .neutral, .skipped].contains(conclusion)
}

/// In some cases there may be multiple check runs reported for a
/// reference. In that case GitHub.com will pick only the latest
/// run for each check name to present in the PR merge footer and
/// only the latest run counts towards the mergeability of a PR.
///
/// We use the check suite id as a proxy for determining what's
/// the "latest" of two check runs with the same name.
///
/// Runs are keyed by the app's and the check's names, so a rerun replaces
/// the run it reran while two apps' checks of the same name both stay.
public func getLatestCheckRunsById(_ checkRuns: [APIRefCheckRun]) -> [APIRefCheckRun] {
    struct Key: Hashable {
        let app: String
        let name: String
        let hasPullRequests: Bool
    }
    var order: [Key] = []
    var latestCheckRunsByName: [Key: APIRefCheckRun] = [:]

    for checkRun in checkRuns {
        // For release branches (maybe other scenarios?), there can be check runs
        // with the same name, but are "push" events not "pull_request" events. For
        // the push events, the pull_request array will be empty. For pull_request,
        // the pull_request array should have the pull_request object in it. We want
        // these runs treated separately even tho they have same name, they are not
        // simply a repeat of the same run as they have a different origination. This
        // feels hacky... but we don't have any other meta data on a check run that
        // differieates these.
        let key = Key(app: checkRun.app?.name ?? "", name: checkRun.name, hasPullRequests: !checkRun.pullRequests.isEmpty)
        guard let current = latestCheckRunsByName[key] else {
            order.append(key)
            latestCheckRunsByName[key] = checkRun
            continue
        }
        if (current.checkSuite?.id ?? Int.min) < (checkRun.checkSuite?.id ?? Int.min) {
            latestCheckRunsByName[key] = checkRun
        }
    }

    return order.compactMap { latestCheckRunsByName[$0] }
}

/// The checks of a ref: its legacy statuses, then the latest of its check
/// runs.
func refChecks(statuses: APIRefStatus?, checkRuns: APIRefCheckRuns?) -> [RefCheck] {
    var checks: [RefCheck] = []
    if let statuses {
        checks.append(contentsOf: statuses.statuses.map(apiStatusToRefCheck))
    }
    if let checkRuns {
        checks.append(contentsOf: getLatestCheckRunsById(checkRuns.checkRuns).map(apiCheckRunToRefCheck))
    }
    return checks
}

/// Retrieve GitHub Actions job and logs for the check runs.
func getLatestPRWorkflowRunsLogsForCheckRun(_ api: API, _ owner: String, _ repo: String, _ checkRuns: [RefCheck]) async -> [RefCheck] {
    var jobsCache: [Int: APIWorkflowJobs?] = [:]
    var mappedCheckRuns: [RefCheck] = []
    for checkRun in checkRuns {
        guard let workflow = checkRun.actionsWorkflow else {
            mappedCheckRuns.append(checkRun)
            continue
        }
        let id = workflow.id
        // Multiple check runs match a single workflow run.
        // We can prevent several job network calls by caching them.
        let workflowRunJobs: APIWorkflowJobs?
        if let cached = jobsCache[id] {
            workflowRunJobs = cached
        } else {
            workflowRunJobs = (try? await api.fetchWorkflowRunJobs(owner: owner, name: repo, workflowRunId: id)) ?? nil
            jobsCache[id] = workflowRunJobs
        }

        guard let matchingJob = workflowRunJobs?.jobs.first(where: { $0.id == checkRun.id }) else {
            mappedCheckRuns.append(checkRun)
            continue
        }

        var mapped = checkRun
        mapped.htmlURL = matchingJob.htmlURL
        mapped.actionJobSteps = matchingJob.steps
        mappedCheckRuns.append(mapped)
    }

    return mappedCheckRuns
}

/// Retrieves the action workflow run for the check runs and if exists updates
/// the actionWorkflow property.
///
/// - Parameters:
///   - account: The account used to retrieve the jobs and logs URLs
///   - owner: Owner of the repository
///   - repo: Name of the repository
///   - branchName: Name of the branch to which the check runs belong
///   - checkRuns: List of check runs to augment
func getCheckRunActionsWorkflowRuns(
    _ account: Account,
    _ owner: String,
    _ repo: String,
    _ branchName: String,
    _ checkRuns: [RefCheck],
    runtime: GitHubRuntime
) async -> [RefCheck] {
    let api = API.fromAccount(account, runtime: runtime)
    if supportsRetrieveActionWorkflowByCheckSuiteId(account.endpoint, runtime: runtime) {
        return await getCheckRunActionsWorkflowRunsByCheckSuiteId(api, owner, repo, checkRuns)
    }
    return await getCheckRunActionsWorkflowRunsByBranchName(api, owner, repo, branchName, checkRuns)
}

/// Retrieves the action workflow runs by using the branchName they are
/// associated with.
///
/// Note: This approach has pit falls because it is possible for a pull request
/// to have check runs initiated from two separate branches and therefore we do
/// not get action workflows that exist for some pr check runs. For example,
/// a release workflow can generate a release branch from the release pr branch.
/// The actions teams added a way to retrieve Action workflows via the check
/// suite id to avoid these pitfalls. However, this will not be immediately
/// available for GitHub Enterprise; thus, we keep approach to maintain GitHub
/// Enterprise Server usage.
private func getCheckRunActionsWorkflowRunsByBranchName(
    _ api: API,
    _ owner: String,
    _ repo: String,
    _ branchName: String,
    _ checkRuns: [RefCheck]
) async -> [RefCheck] {
    let latestWorkflowRuns = await getLatestPRWorkflowRunsByBranchName(api, owner, repo, branchName)

    if latestWorkflowRuns.isEmpty {
        return checkRuns
    }

    return mapActionWorkflowsRunsToCheckRuns(checkRuns, latestWorkflowRuns)
}

/// Retrieves the action workflow runs by using the check suite id.
///
/// If the check run is run using GitHub Actions, then there will be an actions
/// workflow run with a matching check suite id that has the corresponding
/// actions workflow.
private func getCheckRunActionsWorkflowRunsByCheckSuiteId(
    _ api: API,
    _ owner: String,
    _ repo: String,
    _ checkRuns: [RefCheck]
) async -> [RefCheck] {
    if checkRuns.isEmpty {
        return checkRuns
    }

    var mappedCheckRuns: [RefCheck] = []
    var actionsCache: [Int: APIWorkflowRun?] = [:]
    for checkRun in checkRuns {
        guard let checkSuiteID = checkRun.checkSuiteID else {
            mappedCheckRuns.append(checkRun)
            continue
        }

        // Multiple check runs share the same action workflow
        let actionsWorkflow: APIWorkflowRun?
        if let cached = actionsCache[checkSuiteID] {
            actionsWorkflow = cached
        } else {
            actionsWorkflow = (try? await api.fetchPRActionWorkflowRunByCheckSuiteId(
                owner: owner,
                name: repo,
                checkSuiteId: checkSuiteID
            )) ?? nil
            actionsCache[checkSuiteID] = actionsWorkflow
        }

        guard let actionsWorkflow else {
            mappedCheckRuns.append(checkRun)
            continue
        }

        var mapped = checkRun
        mapped.actionsWorkflow = actionsWorkflow
        mappedCheckRuns.append(mapped)
    }

    return mappedCheckRuns
}

/// Gets only the latest PR workflow runs hashed by name
private func getLatestPRWorkflowRunsByBranchName(
    _ api: API,
    _ owner: String,
    _ name: String,
    _ branchName: String
) async -> [APIWorkflowRun] {
    guard let allBranchWorkflowRuns = (try? await api.fetchPRWorkflowRunsByBranchName(
        owner: owner,
        name: name,
        branchName: branchName
    )) ?? nil else {
        return []
    }

    // When retrieving Actions Workflow runs it returns all present and past
    // workflow runs for the given branch name. For each workflow name, we only
    // care about showing the latest run.
    var order: [Int] = []
    var latest: [Int: APIWorkflowRun] = [:]
    for workflowRun in allBranchWorkflowRuns.workflowRuns {
        guard let stored = latest[workflowRun.workflowID] else {
            order.append(workflowRun.workflowID)
            latest[workflowRun.workflowID] = workflowRun
            continue
        }

        let storedDate = parseGitHubTimestamp(stored.createdAt)
        let givenDate = parseGitHubTimestamp(workflowRun.createdAt)
        if let storedDate, let givenDate, storedDate < givenDate {
            latest[workflowRun.workflowID] = workflowRun
        }
    }

    return order.compactMap { latest[$0] }
}

private func mapActionWorkflowsRunsToCheckRuns(_ checkRuns: [RefCheck], _ actionWorkflowRuns: [APIWorkflowRun]) -> [RefCheck] {
    if actionWorkflowRuns.isEmpty || checkRuns.isEmpty {
        return checkRuns
    }

    return checkRuns.map { checkRun in
        guard let matching = actionWorkflowRuns.first(where: { $0.checkSuiteID == checkRun.checkSuiteID }) else {
            return checkRun
        }
        var mapped = checkRun
        mapped.actionsWorkflow = matching
        return mapped
    }
}

/// Gets the duration of a check run or job step formatted in minutes and
/// seconds with short notation (e.g. 1m 30s); empty when it isn't known.
public func getFormattedCheckRunDuration(completedAt: String?, startedAt: String?) -> String {
    getCheckDurationInMilliseconds(completedAt: completedAt, startedAt: startedAt).map(formatPreciseDuration) ?? ""
}

/// Gets the duration of a check run or job step formatted in minutes and
/// seconds with long notation (e.g. 1 minute 30 seconds); empty when it
/// isn't known.
public func getFormattedCheckRunLongDuration(completedAt: String?, startedAt: String?) -> String {
    getCheckDurationInMilliseconds(completedAt: completedAt, startedAt: startedAt).map(formatLongPreciseDuration) ?? ""
}

/// Generates the URL pointing to the details of a given check run. If that check
/// run has no specific URL, returns the URL of the associated pull request.
///
/// - Parameters:
///   - checkRun: Check run to generate the URL for
///   - step: Check run step to generate the URL for
///   - repository: Repository to which the check run belongs
///   - pullRequestNumber: Number of PR associated with the check run
public func getCheckRunStepURL(
    _ checkRun: RefCheck,
    _ step: APIWorkflowJobStep,
    _ repository: GitHubRepository,
    _ pullRequestNumber: Int
) -> String? {
    if let htmlURL = checkRun.htmlURL {
        return "\(htmlURL)/#step:\(step.number):1"
    }
    // A check run may not have a url depending on how it is setup.
    // However, the repository should have one; Thus, we shouldn't hit this
    return repository.htmlURL.map { "\($0)/pull/\(pullRequestNumber)" }
}

/// Groups check runs by their actions workflow name and actions workflow
/// event type. Event type only gets grouped if there are more than one
/// event. Also sorts the check runs in the groups by their names.
///
/// - Returns: The groups, named, in the order the UI lists them
///   (`getCheckRunGroupNames`: alphabetically, with "Other" last).
public func getCheckRunsGroupedByActionWorkflowNameAndEvent(_ checkRuns: [RefCheck]) -> [(name: String, checks: [RefCheck])] {
    let checkRunEvents = Set(checkRuns.compactMap { checkRun -> String? in
        guard let event = checkRun.actionsWorkflow?.event, !JSCompat.trim(event).isEmpty else {
            return nil
        }
        return event
    })
    let checkRunsHaveMultipleEventTypes = checkRunEvents.count > 1

    var order: [String] = []
    var groups: [String: [RefCheck]] = [:]
    for checkRun in checkRuns {
        var group = checkRun.actionsWorkflow?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Other"

        if checkRunsHaveMultipleEventTypes, let workflow = checkRun.actionsWorkflow, !JSCompat.trim(workflow.event).isEmpty {
            group = "\(group) (\(workflow.event))"
        }

        if group == "Other", checkRun.appName == "GitHub Code Scanning" {
            group = "Code scanning results"
        }

        if groups[group] == nil {
            order.append(group)
        }
        groups[group, default: []].append(checkRun)
    }

    return getCheckRunGroupNames(order).map { name in
        (name: name, checks: (groups[name] ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
    }
}

/// Sorts the check run group names alphabetically, with Other being last.
public func getCheckRunGroupNames(_ groupNames: [String]) -> [String] {
    groupNames.sorted { a, b in
        if a == "Other", b != "Other" {
            return false
        }
        if a != "Other", b == "Other" {
            return true
        }
        if a == "Other", b == "Other" {
            return false
        }
        return a.localizedCompare(b) == .orderedAscending
    }
}

/// The checks with `pendingChecks` set back to in progress, as after a rerun.
public func manuallySetChecksToPending(_ cachedChecks: [RefCheck], _ pendingChecks: [RefCheck]) -> CombinedRefCheck? {
    let pendingIDs = Set(pendingChecks.map(\.id))
    let updatedChecks = cachedChecks.map { check -> RefCheck in
        guard pendingIDs.contains(check.id) else {
            return check
        }
        var updated = check
        updated.status = .inProgress
        updated.conclusion = nil
        updated.actionJobSteps = check.actionJobSteps?.map { step in
            APIWorkflowJobStep(
                name: step.name,
                number: step.number,
                status: .inProgress,
                conclusion: nil,
                completedAt: step.completedAt,
                startedAt: step.startedAt,
                log: step.log
            )
        }
        return updated
    }
    return createCombinedCheckFromChecks(updatedChecks)
}

/// Groups and totals the checks by their conclusion if not nil and otherwise
/// by their status, in the order they first appear.
///
/// - Returns: The conclusions or statuses (their API names) and how many
///   checks have each.
public func getCheckStatusCountMap(_ checks: [RefCheck]) -> [(key: String, count: Int)] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for check in checks {
        let key = check.conclusion?.rawValue ?? check.status.rawValue
        if counts[key] == nil {
            order.append(key)
        }
        counts[key, default: 0] += 1
    }
    return order.map { (key: $0, count: counts[$0] ?? 0) }
}

/// An array of check conclusions that are considerd a failure.
public let failingCheckConclusions: [APICheckConclusion] = [
    .failure,
    .canceled,
    .actionRequired,
    .timedOut,
]

// MARK: The checks popover's copy

/// "2 successful, 1 failed, and 1 in progress checks": the conclusions and
/// how many checks (or steps) have each, in the order they first appear.
public func getCombinedStatusSummary(_ conclusions: [APICheckConclusion?], description: String = "check") -> String {
    var order: [APICheckConclusion?] = []
    var counts: [APICheckConclusion?: Int] = [:]
    for conclusion in conclusions {
        if counts[conclusion] == nil {
            order.append(conclusion)
        }
        counts[conclusion, default: 0] += 1
    }
    let parts = order.map { conclusion in
        "\(counts[conclusion] ?? 0) \(JSCompat.toLowerCase(getCheckRunConclusionAdjective(conclusion)))"
    }
    let pluralize = conclusions.count > 1 ? "\(description)s" : description
    return "\(toSentence(parts)) \(pluralize)"
}

/// The checks popover's title for `checks`: "Checks Summary" while loading with
/// nothing to show, "Some checks haven't completed yet", "All checks have
/// failed", "All checks have passed", or "Some checks were not successful".
public func getChecksSummaryTitle(_ checks: [RefCheck], loading: Bool) -> String {
    // Only show the loading title if there are no cached check runs to display.
    let isLoading = loading && checks.isEmpty
    if isLoading {
        return "Checks Summary"
    }

    let somePendingNoFailures = checks.contains { $0.conclusion == nil }
        && !checks.contains { check in check.conclusion.map(failingCheckConclusions.contains) ?? false }
    if somePendingNoFailures {
        return "Some checks haven't completed yet"
    }

    let successfulishConclusions: [APICheckConclusion] = [.success, .neutral, .skipped]
    let allSuccessIsh = !checks.contains { check in
        check.conclusion.map { !successfulishConclusions.contains($0) } ?? false
    }
    let allFailure = !checks.contains { check in
        check.conclusion.map { !failingCheckConclusions.contains($0) } ?? true
    }
    if allFailure {
        return "All checks have failed"
    }
    if allSuccessIsh {
        return "All checks have passed"
    }
    return "Some checks were not successful"
}

/// Which checks can be rerun: the rerun dialog lists `rerunnable` and warns
/// about `nonRerunnable`.
public struct CheckRerunPlan: Sendable, Equatable {
    public let rerunnable: [RefCheck]
    public let nonRerunnable: [RefCheck]
    /// Whether only failed checks were considered.
    public let failedOnly: Bool

    public init(rerunnable: [RefCheck], nonRerunnable: [RefCheck], failedOnly: Bool) {
        self.rerunnable = rerunnable
        self.nonRerunnable = nonRerunnable
        self.failedOnly = failedOnly
    }

    /// The warning about the checks that can't be rerun, or nil when every
    /// check can.
    public var warning: String? {
        guard !nonRerunnable.isEmpty else {
            return nil
        }
        let failed = failedOnly ? "failed " : ""
        let count = nonRerunnable.count
        let prefix = rerunnable.isEmpty
            ? "None of the \(failed)checks can be re-run."
            : "\(count) \(failed)check\(count == 1 ? "" : "s") can't be re-run."
        return "\(prefix) A check can't be re-run when it's more than a month old, when it or a check it depends on "
            + "hasn't finished, or when it isn't set up to be re-run."
    }

    /// What rerunning does: "<name> will run again, along with the checks
    /// that depend on it." for one check, "These workflows will run
    /// again..." for several, or nil when nothing can be rerun.
    public func dependentsMessage(allChecks: [RefCheck]) -> String? {
        guard !rerunnable.isEmpty else {
            return nil
        }
        if allChecks.count == 1 {
            return "\(allChecks[0].name) will run again, along with the checks that depend on it."
        }
        return "These workflows will run again, along with the checks that depend on them."
    }
}

/// Splits the checks to consider (failed ones only, with `failedOnly`) by
/// whether their check suites can be rerun: rerequestable, completed, and
/// under a month old.
func rerunPlan(_ checkRuns: [RefCheck], failedOnly: Bool, checkSuites: [APICheckSuite], now: Date) -> CheckRerunPlan {
    let checkRunsToConsider = failedOnly ? checkRuns.filter { $0.conclusion == .failure } : checkRuns
    let monthAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)

    var rerequestableCheckSuiteIDs: Set<Int> = []
    for checkSuite in checkSuites {
        let createdAt = checkSuite.createdAt.flatMap(parseGitHubTimestamp)
        if checkSuite.rerequestable == true,
           let createdAt, createdAt > monthAgo, // Must be less than a month old
           checkSuite.status == .completed // Must be completed
        {
            rerequestableCheckSuiteIDs.insert(checkSuite.id)
        }
    }

    let rerunnable = checkRunsToConsider.filter { check in
        check.checkSuiteID.map(rerequestableCheckSuiteIDs.contains) ?? false
    }
    let nonRerunnable = checkRunsToConsider.filter { check in
        !(check.checkSuiteID.map(rerequestableCheckSuiteIDs.contains) ?? false)
    }
    return CheckRerunPlan(rerunnable: rerunnable, nonRerunnable: nonRerunnable, failedOnly: failedOnly)
}

// MARK: Durations

private struct TimeUnitDescriptor {
    let shortUnit: String
    let longUnit: String
    let ms: Double
}

private let units: [TimeUnitDescriptor] = [
    TimeUnitDescriptor(shortUnit: "d", longUnit: "day", ms: 86_400_000),
    TimeUnitDescriptor(shortUnit: "h", longUnit: "hour", ms: 3_600_000),
    TimeUnitDescriptor(shortUnit: "m", longUnit: "minute", ms: 60000),
    TimeUnitDescriptor(shortUnit: "s", longUnit: "second", ms: 1000),
]

/// Creates a narrow style precise duration format used for displaying things
/// like check run durations that typically only last for a few minutes.
///
/// Example: formatPreciseDuration(3670000) -> "1h 1m 10s"
///
/// - Parameter ms: The duration in milliseconds
public func formatPreciseDuration(_ ms: Double) -> String {
    var parts: [String] = []
    var ms = abs(ms)

    for unit in units where !parts.isEmpty || ms >= unit.ms || unit.shortUnit == "s" {
        let qty = (ms / unit.ms).rounded(.down)
        ms -= qty * unit.ms
        parts.append("\(Int(qty))\(unit.shortUnit)")
    }

    return parts.joined(separator: " ")
}

/// Creates a long style precise duration format used for displaying things
/// like check run durations that typically only last for a few minutes.
///
/// Example: formatLongPreciseDuration(3670000) -> "1 hour 1 minute 10 seconds"
///
/// - Parameter ms: The duration in milliseconds
public func formatLongPreciseDuration(_ ms: Double) -> String {
    var parts: [String] = []
    var ms = abs(ms)

    for unit in units where !parts.isEmpty || ms >= unit.ms || unit.shortUnit == "s" {
        let qty = (ms / unit.ms).rounded(.down)
        ms -= qty * unit.ms
        parts.append("\(Int(qty)) \(unit.longUnit)\(qty == 1 ? "" : "s")")
    }

    return parts.joined(separator: " ")
}

// MARK: Sentences

/// Joins `array` as a sentence: "a", "a and b", "a, b, and c".
public func toSentence(_ array: [String]) -> String {
    let wordsConnector = ", "
    let twoWordsConnector = " and "
    let lastWordConnector = ", and "

    switch array.count {
    case 0:
        return ""
    case 1:
        return array[0]
    case 2:
        return array[0] + twoWordsConnector + array[1]
    default:
        return array.dropLast().joined(separator: wordsConnector) + lastWordConnector + array[array.count - 1]
    }
}
