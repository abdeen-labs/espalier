// Ported from desktop/app/test/unit/ci-checks-test.ts
// Plus tests of the rest of CIChecks.swift.

@testable import EspalierCore
import Foundation
import GitHubKit
import Testing
import TestSupport

@Suite("getCheckRunsGroupedByActionWorkflowNameAndEvent")
struct CheckRunGroupingTests {
    private func groupNames(_ checkRuns: [RefCheck]) -> [String] {
        getCheckRunsGroupedByActionWorkflowNameAndEvent(checkRuns).map(\.name)
    }

    @Test("groups by workflow name, else by app into Code scanning results or Other", arguments: [
        NamedCase("groups by actions workflow name", (
            checkRuns: [
                buildMockCheckRun("1", "", "test1"),
                buildMockCheckRun("1", "", "test2"),
            ],
            groups: ["test1", "test2"]
        )),
        NamedCase("groups any check run without an actions workflow name with an app name of \"GitHub Code Scanning\" into \"Code scanning results\"", (
            checkRuns: [
                buildMockCheckRun("1", "", "test1"),
                buildMockCheckRun("1", ""),
                buildMockCheckRun("1", "GitHub Code Scanning"),
            ],
            groups: ["test1", "Other", "Code scanning results"]
        )),
    ])
    func groups(_ testCase: NamedCase<(checkRuns: [RefCheck], groups: [String])>) {
        let names = groupNames(testCase.value.checkRuns)
        for group in testCase.value.groups {
            #expect(names.contains(group))
        }
    }

    @Test("groups by actions event type if more than one event type")
    func byEventType() {
        var checkRuns = [
            buildMockCheckRun("1", "", "test1"),
            buildMockCheckRun("1", "", "test2"),
        ]
        var names = groupNames(checkRuns)

        // no event types
        #expect(names.contains("test1"))
        #expect(names.contains("test2"))

        checkRuns.append(buildMockCheckRun("1", "", "test3", "pull_request"))
        names = groupNames(checkRuns)

        // only one event
        #expect(names.contains("test1"))
        #expect(names.contains("test2"))
        #expect(names.contains("test3"))

        checkRuns.append(buildMockCheckRun("1", "", "test4", "push"))
        names = groupNames(checkRuns)

        // two event types for test3 and test4
        #expect(names.contains("test1"))
        #expect(names.contains("test2"))
        #expect(names.contains("test3 (pull_request)"))
        #expect(names.contains("test4 (push)"))
    }

    @Test("lists the groups alphabetically with Other last, each sorted by name")
    func order() {
        let checkRuns = [
            buildMockCheckRun("b", ""),
            buildMockCheckRun("z", "", "Zeta"),
            buildMockCheckRun("a", ""),
            buildMockCheckRun("y", "", "Alpha"),
            buildMockCheckRun("x", "", "Alpha"),
        ]
        let groups = getCheckRunsGroupedByActionWorkflowNameAndEvent(checkRuns)
        #expect(groups.map(\.name) == ["Alpha", "Zeta", "Other"])
        #expect(groups[0].checks.map(\.name) == ["x", "y"])
        #expect(groups[2].checks.map(\.name) == ["a", "b"])
    }
}

private func buildMockCheckRun(
    _ name: String,
    _ appName: String = "",
    _ actionWorkflowName: String? = nil,
    _ actionWorkflowEvent: String? = nil
) -> RefCheck {
    RefCheck(
        id: 1,
        name: name,
        description: "",
        status: .completed,
        conclusion: .success,
        appName: appName,
        htmlURL: nil,
        checkSuiteID: nil,
        actionsWorkflow: actionWorkflowName != nil || actionWorkflowEvent != nil
            ? APIWorkflowRun(
                id: 1,
                workflowID: 1,
                cancelURL: "",
                createdAt: "",
                logsURL: "",
                name: actionWorkflowName ?? "",
                rerunURL: "",
                checkSuiteID: 1,
                event: actionWorkflowEvent ?? ""
            )
            : nil
    )
}

/// A check run as the API sends it.
func apiCheckRun(
    id: Int,
    name: String,
    status: APICheckStatus = .completed,
    conclusion: APICheckConclusion? = .success,
    app: String = "GitHub Actions",
    checkSuite: Int? = 100,
    startedAt: String? = "2026-10-01T10:00:00Z",
    completedAt: String? = "2026-10-01T10:01:02Z",
    htmlURL: String? = nil,
    pullRequests: [APICheckRunPullRequest] = [APICheckRunPullRequest(id: 1, number: 1)]
) -> APIRefCheckRun {
    APIRefCheckRun(
        id: id,
        url: "https://api.github.com/check-runs/\(id)",
        status: status,
        conclusion: status == .completed ? conclusion : nil,
        name: name,
        checkSuite: checkSuite.map(APIRefCheckRunCheckSuite.init),
        app: APIRefCheckRunApp(name: app),
        completedAt: status == .completed ? completedAt : nil,
        startedAt: startedAt,
        htmlURL: htmlURL ?? "https://github.com/octocat/hello/runs/\(id)",
        pullRequests: pullRequests
    )
}

/// A check as the store keeps it.
func refCheck(
    id: Int,
    name: String = "check",
    status: APICheckStatus = .completed,
    conclusion: APICheckConclusion? = .success,
    checkSuiteID: Int? = 100,
    actionsWorkflow: APIWorkflowRun? = nil
) -> RefCheck {
    RefCheck(
        id: id,
        name: name,
        description: "",
        status: status,
        conclusion: conclusion,
        appName: "GitHub Actions",
        htmlURL: nil,
        checkSuiteID: checkSuiteID,
        actionsWorkflow: actionsWorkflow
    )
}

@Suite("CI checks")
struct CIChecksTests {
    @Test("checks add up to failed, else running, else unfinished, else passed; the combined check follows", arguments: [
        NamedCase("no checks: none", (checks: [APICheckConclusion?](), result: CheckResult?.none, combined: APICheckConclusion?.none)),
        NamedCase("one running check runs", ([nil], .running, nil)),
        NamedCase("a failure fails, beside a running check", ([nil, .failure], .failed, .failure)),
        NamedCase("timing out fails", ([.success, .timedOut], .failed, .failure)),
        NamedCase("needing an action fails", ([.success, .actionRequired], .failed, .failure)),
        NamedCase("one cancelled check is unfinished, not failed", ([.canceled], .unfinished, .canceled)),
        NamedCase("a cancelled check beside a pass is unfinished", ([.success, .canceled], .unfinished, .canceled)),
        NamedCase("a stale check beside a running one still runs", ([.stale, nil], .running, nil)),
        NamedCase("only stale checks unfinished: stale", ([.success, .stale], .unfinished, .stale)),
        NamedCase("a conclusion GitHub added since is unfinished", ([.success, APICheckConclusion(rawValue: "something_new")], .unfinished, .canceled)),
        NamedCase("success, neutral, and skipped pass", ([.success, .neutral, .skipped], .passed, .success)),
        NamedCase("one skipped check passes", ([.skipped], .passed, .success)),
    ])
    func results(_ testCase: NamedCase<(checks: [APICheckConclusion?], result: CheckResult?, combined: APICheckConclusion?)>) {
        let checks = testCase.value.checks.enumerated().map { index, conclusion in
            refCheck(id: index + 1, status: conclusion == nil ? .inProgress : .completed, conclusion: conclusion)
        }
        #expect(checksResult(checks) == testCase.value.result)
        let combined = createCombinedCheckFromChecks(checks)
        #expect(combined?.checks == (checks.isEmpty ? nil : checks))
        #expect(combined?.conclusion == testCase.value.combined)
        #expect(combined.map { $0.status == .completed } == testCase.value.result.map { $0 != .running })
    }

    @Test("a check run keeps its app, check suite, and URL")
    func checkRunFields() {
        let check = apiCheckRunToRefCheck(apiCheckRun(id: 9, name: "build", checkSuite: 42))
        #expect(check.appName == "GitHub Actions")
        #expect(check.checkSuiteID == 42)
        #expect(check.htmlURL == "https://github.com/octocat/hello/runs/9")
    }

    @Test("a rerun's run replaces the one it reran in its check suite; same-named runs in other suites stay")
    func latestCheckRuns() {
        let runs = [
            // ci.yml's build fails; docs.yml's build passes.
            apiCheckRun(id: 1, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 2, name: "build", checkSuite: 101),
            // test failed, then its rerun passed, in the same suite.
            apiCheckRun(id: 3, name: "test", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 4, name: "test", checkSuite: 100),
            // A push's run beside the pull request's.
            apiCheckRun(id: 5, name: "build", checkSuite: 102, pullRequests: []),
            apiCheckRun(id: 6, name: "lint", checkSuite: nil),
            apiCheckRun(id: 7, name: "lint", checkSuite: nil),
        ]
        let latest = getLatestCheckRunsById(runs)
        #expect(latest.map(\.id) == [1, 2, 4, 5, 6, 7])
        #expect(checksResult(latest.map(apiCheckRunToRefCheck)) == .failed)
    }

    @Test("rerun checks show in progress, with their steps")
    func pendingAfterRerun() throws {
        let step = APIWorkflowJobStep(name: "Run", number: 1, status: .completed, conclusion: .failure, completedAt: nil, startedAt: nil)
        var failing = refCheck(id: 1, conclusion: .failure)
        failing.actionJobSteps = [step]
        let other = refCheck(id: 2, conclusion: .success)

        let combined = try #require(manuallySetChecksToPending([failing, other], [failing]))
        #expect(combined.checks[0].status == .inProgress)
        #expect(combined.checks[0].conclusion == nil)
        #expect(combined.checks[0].actionJobSteps?.first?.status == .inProgress)
        #expect(combined.checks[0].actionJobSteps?.first?.conclusion == nil)
        #expect(combined.checks[1] == other)
        #expect(combined.status == .inProgress)
    }

    @Test("checks rerun when their suite is rerequestable, completed, and under a month old")
    func rerunnability() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func createdAt(daysAgo: Double) -> String {
            gitHubTimestamp(now.addingTimeInterval(-daysAgo * 24 * 60 * 60))
        }
        let checks = [
            refCheck(id: 1, conclusion: .failure, checkSuiteID: 1),
            refCheck(id: 2, conclusion: .success, checkSuiteID: 2),
            refCheck(id: 3, conclusion: .failure, checkSuiteID: 3),
            refCheck(id: 4, conclusion: .failure, checkSuiteID: 4),
            refCheck(id: 5, conclusion: .failure, checkSuiteID: nil),
            refCheck(id: 6, conclusion: .timedOut, checkSuiteID: 1),
            refCheck(id: 7, conclusion: .actionRequired, checkSuiteID: 1),
        ]
        let suites = [
            APICheckSuite(id: 1, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 1)),
            APICheckSuite(id: 2, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 2)),
            APICheckSuite(id: 3, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 31)),
            APICheckSuite(id: 4, rerequestable: true, runsRerequestable: true, status: .inProgress, createdAt: createdAt(daysAgo: 1)),
        ]

        let all = rerunPlan(checks, failedOnly: false, checkSuites: suites, now: now)
        #expect(all.rerunnable.map(\.id) == [1, 2, 6, 7])
        #expect(all.nonRerunnable.map(\.id) == [3, 4, 5])
        #expect(all.warning != nil)
        #expect(all.dependentsMessage(allChecks: checks) != nil)

        // Timed out and needing an action count as failed.
        let failed = rerunPlan(checks, failedOnly: true, checkSuites: suites, now: now)
        #expect(failed.rerunnable.map(\.id) == [1, 6, 7])
        #expect(failed.nonRerunnable.map(\.id) == [3, 4, 5])
        #expect(failed.warning != nil)

        let none = rerunPlan([checks[2]], failedOnly: true, checkSuites: suites, now: now)
        #expect(none.warning != nil)
        #expect(none.dependentsMessage(allChecks: [checks[2]]) == nil)

        let one = rerunPlan([checks[0]], failedOnly: false, checkSuites: suites, now: now)
        #expect(one.warning == nil)
        #expect(one.dependentsMessage(allChecks: [checks[0]]) != nil)
    }

    @Test("a step's URL is its check run's, else the pull request's")
    func stepURL() {
        let step = APIWorkflowJobStep(name: "Build", number: 3, status: .completed, conclusion: .success, completedAt: nil, startedAt: nil)
        let repository = GitHubRepository(name: "hello", owner: Owner(login: "octocat", endpoint: "https://api.github.com", id: 1), dbID: 1, htmlURL: "https://github.com/octocat/hello")
        var check = refCheck(id: 1)
        #expect(getCheckRunStepURL(check, step, repository, 7) == "https://github.com/octocat/hello/pull/7")
        check.htmlURL = "https://github.com/octocat/hello/actions/runs/5/job/1"
        #expect(getCheckRunStepURL(check, step, repository, 7) == "https://github.com/octocat/hello/actions/runs/5/job/1/#step:3:1")
    }

    @Test("counts checks by conclusion, else status, in order of appearance")
    func statusCounts() {
        let counts = getCheckStatusCountMap([
            refCheck(id: 1, conclusion: .failure),
            refCheck(id: 2, status: .queued, conclusion: nil),
            refCheck(id: 3, conclusion: .failure),
            refCheck(id: 4, conclusion: .success),
        ])
        #expect(counts.map(\.key) == ["failure", "queued", "success"])
        #expect(counts.map(\.count) == [2, 1, 1])
    }
}
