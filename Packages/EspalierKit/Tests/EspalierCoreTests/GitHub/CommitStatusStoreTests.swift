// Subscriptions loading a pull request's checks against a mock GitHub, the
// 3-minute refresh while active (with a `ManualScheduler`), the 60-second
// eligibility, GitHub Actions' workflows and steps, paged and failed loads,
// reruns and the ones GitHub refuses, and the rerun plan.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private let statusPath = "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/status"
private let checkRunsPath = "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/check-runs"

@Suite("Commit status store", .offline, .hangGuard(minutes: 5)) @MainActor
struct CommitStatusStoreTests {
    private func pullRequest(_ fixture: GitHubFixture) async throws -> PullRequest {
        await fixture.model.gitHub.refreshPullRequests()
        return try #require(fixture.model.gitHub.openPullRequests.first)
    }

    private func fixture(
        statuses: [APIRefStatusItem] = [],
        runs: [APIRefCheckRun] = [apiCheckRun(id: 11, name: "build")],
        mock: @escaping (MockGitHub) -> Void = { _ in }
    ) async throws -> GitHubFixture {
        try await makeGitHubFixture { gitHub, pulls in
            pulls.open = [apiPullRequest(5)]
            gitHub.on("GET", statusPath, respond: .json(encoding: CommitStatusStoreTests.status(statuses)))
            gitHub.on("GET", checkRunsPath, respond: .json(encoding: APIRefCheckRuns(totalCount: runs.count, checkRuns: runs)))
            mock(gitHub)
        }
    }

    private static func status(_ items: [APIRefStatusItem]) -> APIRefStatus {
        APIRefStatus(state: .success, totalCount: items.count, statuses: items)
    }

    @Test("subscribing loads a pull request's checks: its statuses and check runs, combined")
    func subscribe() async throws {
        let fixture = try await fixture(
            statuses: [APIRefStatusItem(state: .pending, targetURL: nil, description: nil, context: "ci/legacy", id: 3)],
            runs: [apiCheckRun(id: 11, name: "build"), apiCheckRun(id: 12, name: "test", conclusion: .failure)]
        )
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        #expect(gitHub.checks(for: pr) == nil)
        #expect(!gitHub.commitStatuses.hasLoaded(CheckRunsKey(pr)))

        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pr))
        await gitHub.idle()
        let check = try #require(gitHub.checks(for: pr))
        #expect(check.checks.map(\.name) == ["ci/legacy", "build", "test"])
        #expect(check.status == .completed)
        #expect(check.conclusion == .failure)
        #expect(gitHub.commitStatuses.hasLoaded(CheckRunsKey(pr)))
        #expect(fixture.gitHub.requests("GET", checkRunsPath).first?.header("Accept") == "application/vnd.github.antiope-preview+json")
        subscription.cancel()
        await fixture.settle()
    }

    @Test("while active, subscribed checks refresh every 3 minutes; never within a minute; not while inactive")
    func backgroundRefresh() async throws {
        let fixture = try await fixture()
        let pr = try await pullRequest(fixture)
        let store = fixture.model.gitHub.commitStatuses
        let subscription = store.subscribe(CheckRunsKey(pr))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 1)
        #expect(store.isRefreshingInBackground)

        // A second subscription to the same ref within a minute loads nothing.
        let second = store.subscribe(CheckRunsKey(pr))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 1)
        second.cancel()

        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 2)

        fixture.app.setActive(false)
        await settle(until: { !store.isRefreshingInBackground })
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 2)

        // Becoming active refreshes at once.
        fixture.app.setActive(true)
        await settle(until: { store.isRefreshingInBackground })
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 3)

        subscription.cancel()
        #expect(!store.isRefreshingInBackground)
        #expect(store.check(for: CheckRunsKey(pr)) != nil)
        await fixture.settle()
    }

    @Test("watching keeps the checks loaded until the task is cancelled")
    func watch() async throws {
        let fixture = try await fixture()
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        let watching = Task { await gitHub.watchChecks(for: pr) }
        await waitForState { gitHub.checks(for: pr) != nil }
        #expect(gitHub.commitStatuses.subscribedKeys == [CheckRunsKey(pr)])
        watching.cancel()
        await watching.value
        #expect(gitHub.commitStatuses.subscribedKeys.isEmpty)
        await fixture.settle()
    }

    @Test("a failed load keeps the last checks and tries again on schedule")
    func failedLoad() async throws {
        let fixture = try await fixture()
        let pr = try await pullRequest(fixture)
        let store = fixture.model.gitHub.commitStatuses
        let subscription = store.subscribe(CheckRunsKey(pr))
        await fixture.model.gitHub.idle()
        let loaded = try #require(store.check(for: CheckRunsKey(pr)))

        fixture.gitHub.on("GET", statusPath, respond: .status(500))
        fixture.gitHub.on("GET", checkRunsPath, respond: .status(500))
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 2)
        #expect(store.check(for: CheckRunsKey(pr)) == loaded)

        // No checks at all clears them.
        fixture.gitHub.on("GET", statusPath, respond: .json(encoding: Self.status([])))
        fixture.gitHub.on("GET", checkRunsPath, respond: .json(encoding: APIRefCheckRuns(totalCount: 0, checkRuns: [])))
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(store.check(for: CheckRunsKey(pr)) == nil)
        #expect(store.hasLoaded(CheckRunsKey(pr)))
        subscription.cancel()
        await fixture.settle()
    }

    @Test("with a branch name, GitHub Actions' workflow runs and job steps load, and are reused while the checks stay the same")
    func actionsWorkflows() async throws {
        let workflowRun = APIWorkflowRun(
            id: 900,
            workflowID: 1,
            cancelURL: "",
            createdAt: "2026-10-01T10:00:00Z",
            logsURL: "",
            name: "CI",
            rerunURL: "",
            checkSuiteID: 100,
            event: "pull_request"
        )
        let step = APIWorkflowJobStep(name: "Compile", number: 1, status: .completed, conclusion: .success, completedAt: nil, startedAt: nil)
        let fixture = try await fixture(runs: [apiCheckRun(id: 11, name: "build", checkSuite: 100)]) { gitHub in
            gitHub.on("GET", "/repos/octocat/hello/actions/runs", respond: .json(encoding: APIWorkflowRuns(totalCount: 1, workflowRuns: [workflowRun])))
            gitHub.on("GET", "/repos/octocat/hello/actions/runs/900/jobs", respond: .json(encoding: APIWorkflowJobs(totalCount: 1, jobs: [
                APIWorkflowJob(id: 11, name: "build", status: .completed, conclusion: .success, completedAt: nil, startedAt: "2026-10-01T10:00:00Z", steps: [step], htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/11"),
            ])))
        }
        let pr = try await pullRequest(fixture)
        let store = fixture.model.gitHub.commitStatuses
        let subscription = store.subscribe(CheckRunsKey(pr), branchName: "feature")
        await fixture.model.gitHub.idle()

        let check = try #require(store.check(for: CheckRunsKey(pr), branchName: "feature")?.checks.first)
        #expect(check.actionsWorkflow == workflowRun)
        #expect(check.actionJobSteps == [step])
        #expect(check.htmlURL == "https://github.com/octocat/hello/actions/runs/900/job/11")
        let runsRequest = try #require(fixture.gitHub.requests("GET", "/repos/octocat/hello/actions/runs").first)
        #expect(runsRequest.query["check_suite_id"] == "100")
        #expect(runsRequest.query["event"] == "pull_request")
        // Without the subscription's branch name, the cached checks don't show.
        #expect(store.check(for: CheckRunsKey(pr), branchName: "other") == nil)

        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 2)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/actions/runs").count == 1)
        #expect(store.check(for: CheckRunsKey(pr))?.checks.first?.actionJobSteps == [step])
        subscription.cancel()
        await fixture.settle()
    }

    @Test("a subscriber that names no branch keeps the branch another named; once that one goes, the checks load without workflows")
    func branchNameIsKept() async throws {
        let workflowRun = APIWorkflowRun(
            id: 900, workflowID: 1, cancelURL: "", createdAt: "2026-10-01T10:00:00Z", logsURL: "", name: "CI", rerunURL: "", checkSuiteID: 100, event: "pull_request"
        )
        let step = APIWorkflowJobStep(name: "Compile", number: 1, status: .completed, conclusion: .success, completedAt: nil, startedAt: nil)
        let fixture = try await fixture(runs: [apiCheckRun(id: 11, name: "build", checkSuite: 100)]) { gitHub in
            gitHub.on("GET", "/repos/octocat/hello/actions/runs", respond: .json(encoding: APIWorkflowRuns(totalCount: 1, workflowRuns: [workflowRun])))
            gitHub.on("GET", "/repos/octocat/hello/actions/runs/900/jobs", respond: .json(encoding: APIWorkflowJobs(totalCount: 1, jobs: [
                APIWorkflowJob(id: 11, name: "build", status: .completed, conclusion: .success, completedAt: nil, startedAt: "2026-10-01T10:00:00Z", steps: [step], htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/11"),
            ])))
        }
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        let store = gitHub.commitStatuses
        let key = CheckRunsKey(pr)

        // The checks popover (or the pull request's place) names the branch.
        let popover = store.subscribe(key, branchName: "feature")
        await gitHub.idle()
        #expect(store.hasLoaded(key, branchName: "feature"))
        #expect(gitHub.hasLoadedChecks(for: pr, branchName: "feature"))

        // A sidebar row's glyph names none: nothing reloads, the steps stay.
        let row = store.subscribe(key)
        await gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 1)
        #expect(store.check(for: key, branchName: "feature")?.checks.first?.actionJobSteps == [step])
        #expect(store.hasLoaded(key, branchName: "feature"))

        // Without the popover, the next refresh loads no workflows.
        popover.cancel()
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).count == 2)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/actions/runs").count == 1)
        #expect(!store.hasLoaded(key, branchName: "feature"))
        #expect(store.check(for: key, branchName: "feature") == nil)
        #expect(store.check(for: key)?.checks.first?.actionJobSteps == nil)
        #expect(gitHub.hasLoadedChecks(for: pr))
        row.cancel()
        await fixture.settle()
    }

    @Test("reruns: one Actions check reruns its job, failed ones their workflow runs' failed jobs, others their suites; then they show in progress")
    func reruns() async throws {
        let workflow = APIWorkflowRun(id: 900, workflowID: 1, cancelURL: "", createdAt: "", logsURL: "", name: "CI", rerunURL: "", checkSuiteID: 100, event: "pull_request")
        let fixture = try await fixture(runs: [
            apiCheckRun(id: 11, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 12, name: "lint", conclusion: .failure, app: "Lint App", checkSuite: 200),
        ]) { gitHub in
            gitHub.on("POST", "/repos/octocat/hello/actions/jobs/11/rerun", respond: .status(201))
            gitHub.on("POST", "/repos/octocat/hello/actions/runs/900/rerun-failed-jobs", respond: .status(201))
            gitHub.on("POST", "/repos/octocat/hello/check-suites/200/rerequest", respond: .status(201))
            gitHub.on("POST", "/repos/octocat/hello/check-suites/100/rerequest", respond: .json(["message": "Must have admin rights to Repository."], status: 403))
            gitHub.on("GET", "/repos/octocat/hello/check-suites/100", respond: .json(encoding: APICheckSuite(
                id: 100, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: "2026-10-01T10:00:00Z"
            )))
            gitHub.on("GET", "/repos/octocat/hello/check-suites/200", respond: .json(encoding: APICheckSuite(
                id: 200, rerequestable: false, runsRerequestable: false, status: .completed, createdAt: "2026-10-01T10:00:00Z"
            )))
        }
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pr))
        await gitHub.idle()
        let loaded = try #require(gitHub.checks(for: pr)).checks
        var build = loaded[0]
        build.actionsWorkflow = workflow
        let lint = loaded[1]

        // The plan: suite 200 can't be rerequested.
        let plan = await gitHub.rerunPlan(for: pr, checks: [build, lint], failedOnly: true)
        #expect(plan.rerunnable.map(\.id) == [11])
        #expect(plan.nonRerunnable.map(\.id) == [12])

        // GitHub refuses suite 100: the check stays as it was, with GitHub's
        // reason.
        let refused = await gitHub.rerunChecks(CheckRerunPlan(rerunnable: [loaded[0]], nonRerunnable: [], failedOnly: false), for: pr)
        #expect(refused.accepted.isEmpty)
        #expect(refused.refused.map(\.id) == [11])
        #expect(refused.reasons == ["Must have admin rights to Repository."])
        #expect(refused.failureMessage != nil)
        #expect(gitHub.checks(for: pr)?.checks.map(\.conclusion) == [.failure, .failure])

        let job = await gitHub.rerunChecks(CheckRerunPlan(rerunnable: [build], nonRerunnable: [], failedOnly: false), for: pr)
        #expect(job == CheckRerunResult(accepted: [build], refused: [], reasons: []))
        #expect(job.failureMessage == nil)
        #expect(fixture.gitHub.requests("POST", "/repos/octocat/hello/actions/jobs/11/rerun").count == 1)
        #expect(gitHub.checks(for: pr)?.checks.map(\.status) == [.inProgress, .completed])

        let failed = await gitHub.rerunChecks(CheckRerunPlan(rerunnable: [build, lint], nonRerunnable: [], failedOnly: true), for: pr)
        #expect(failed.accepted.map(\.id) == [11, 12])
        #expect(fixture.gitHub.requests("POST", "/repos/octocat/hello/actions/runs/900/rerun-failed-jobs").count == 1)
        #expect(fixture.gitHub.requests("POST", "/repos/octocat/hello/check-suites/200/rerequest").count == 1)
        subscription.cancel()
        await fixture.settle()
    }

    @Test("of a rerun's requests, only the checks of those GitHub accepts show in progress; the others keep their state")
    func partlyRefusedRerun() async throws {
        let workflow = APIWorkflowRun(id: 900, workflowID: 1, cancelURL: "", createdAt: "", logsURL: "", name: "CI", rerunURL: "", checkSuiteID: 100, event: "pull_request")
        let fixture = try await fixture(runs: [
            apiCheckRun(id: 11, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 12, name: "lint", conclusion: .timedOut, app: "Lint App", checkSuite: 200),
        ]) { gitHub in
            gitHub.on("POST", "/repos/octocat/hello/actions/runs/900/rerun-failed-jobs", respond: .status(201))
            gitHub.on("POST", "/repos/octocat/hello/check-suites/200/rerequest", respond: .networkError(.notConnectedToInternet))
        }
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pr))
        await gitHub.idle()
        let loaded = try #require(gitHub.checks(for: pr)).checks
        var build = loaded[0]
        build.actionsWorkflow = workflow

        let result = await gitHub.rerunChecks(CheckRerunPlan(rerunnable: [build, loaded[1]], nonRerunnable: [], failedOnly: true), for: pr)
        #expect(result.accepted.map(\.id) == [11])
        #expect(result.refused.map(\.id) == [12])
        #expect(result.reasons.count == 1)
        let checks = try #require(gitHub.checks(for: pr)).checks
        #expect(checks.map(\.status) == [.inProgress, .completed])
        #expect(checks[1].conclusion == .timedOut)
        subscription.cancel()
        await fixture.settle()
    }

    @Test("Re-run Failed offers checks that timed out or need an action")
    func rerunPlanCountsTimedOut() async throws {
        let fixture = try await fixture(runs: [
            apiCheckRun(id: 11, name: "build", conclusion: .timedOut, checkSuite: 100),
            apiCheckRun(id: 12, name: "deploy", conclusion: .actionRequired, checkSuite: 100),
            apiCheckRun(id: 13, name: "lint", checkSuite: 100),
        ]) { gitHub in
            gitHub.on("GET", "/repos/octocat/hello/check-suites/100", respond: .json(encoding: APICheckSuite(
                id: 100, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: "2026-10-01T10:00:00Z"
            )))
        }
        let pr = try await pullRequest(fixture)
        let gitHub = fixture.model.gitHub
        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pr))
        await gitHub.idle()
        let checks = try #require(gitHub.checks(for: pr)).checks

        let plan = await gitHub.rerunPlan(for: pr, checks: checks, failedOnly: true)
        #expect(plan.rerunnable.map(\.id) == [11, 12])
        subscription.cancel()
        await fixture.settle()
    }

    @Test("checks come from every page; a load where a page or either request fails keeps the last checks")
    func pagedAndHalfFailedLoads() async throws {
        let next = "<https://api.github.com\(checkRunsPath)?per_page=100&page=2>; rel=\"next\""
        let fixture = try await fixture { gitHub in
            gitHub.on("GET", checkRunsPath) { request in
                if request.query["page"] == "2" {
                    return .json(encoding: APIRefCheckRuns(totalCount: 2, checkRuns: [apiCheckRun(id: 12, name: "test", conclusion: .failure)]))
                }
                return .json(encoding: APIRefCheckRuns(totalCount: 2, checkRuns: [apiCheckRun(id: 11, name: "build")]), headers: ["Link": next])
            }
        }
        let pr = try await pullRequest(fixture)
        let store = fixture.model.gitHub.commitStatuses
        let subscription = store.subscribe(CheckRunsKey(pr))
        await fixture.model.gitHub.idle()
        // The failure on the second page counts.
        let loaded = try #require(store.check(for: CheckRunsKey(pr)))
        #expect(loaded.checks.map(\.id) == [11, 12])
        #expect(loaded.conclusion == .failure)

        // The statuses fail; the check runs alone would read as passed.
        fixture.gitHub.on("GET", statusPath, respond: .status(500))
        fixture.gitHub.on("GET", checkRunsPath, respond: .json(encoding: APIRefCheckRuns(totalCount: 1, checkRuns: [apiCheckRun(id: 11, name: "build")])))
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", statusPath).count == 2)
        #expect(store.check(for: CheckRunsKey(pr)) == loaded)

        // The second page of check runs fails.
        fixture.gitHub.on("GET", statusPath, respond: .json(encoding: Self.status([])))
        fixture.gitHub.on("GET", checkRunsPath) { request in
            if request.query["page"] == "2" {
                return .status(500)
            }
            return .json(encoding: APIRefCheckRuns(totalCount: 2, checkRuns: [apiCheckRun(id: 11, name: "build")]), headers: ["Link": next])
        }
        await fixture.scheduler.advance(by: .seconds(3 * 60))
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", checkRunsPath).last?.query["page"] == "2")
        #expect(store.check(for: CheckRunsKey(pr)) == loaded)
        subscription.cancel()
        await fixture.settle()
    }
}
