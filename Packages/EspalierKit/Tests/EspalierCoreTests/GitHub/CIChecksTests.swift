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
    @Test("no checks combine into none; one check is mirrored")
    func combineFew() throws {
        #expect(createCombinedCheckFromChecks([]) == nil)
        let pending = refCheck(id: 1, status: .inProgress, conclusion: nil)
        let combined = try #require(createCombinedCheckFromChecks([pending]))
        #expect(combined.status == .inProgress)
        #expect(combined.conclusion == nil)
        #expect(combined.checks == [pending])
    }

    @Test("any failure, or incomplete check, fails the combination, even with others pending")
    func combineFailure() throws {
        for conclusion in [APICheckConclusion.failure, .actionRequired, .timedOut, .stale, .canceled] {
            let combined = try #require(createCombinedCheckFromChecks([
                refCheck(id: 1, status: .inProgress, conclusion: nil),
                refCheck(id: 2, conclusion: conclusion),
            ]))
            #expect(combined.status == .completed)
            #expect(combined.conclusion == .failure)
        }
    }

    @Test("success, neutral, and skipped combine into success; otherwise in progress")
    func combineSuccess() throws {
        let success = try #require(createCombinedCheckFromChecks([
            refCheck(id: 1, conclusion: .success),
            refCheck(id: 2, conclusion: .neutral),
            refCheck(id: 3, conclusion: .skipped),
        ]))
        #expect(success.status == .completed)
        #expect(success.conclusion == .success)

        let pending = try #require(createCombinedCheckFromChecks([
            refCheck(id: 1, conclusion: .success),
            refCheck(id: 2, status: .queued, conclusion: nil),
        ]))
        #expect(pending.status == .inProgress)
        #expect(pending.conclusion == nil)
    }

    @Test("a check run keeps its app, check suite, and URL")
    func checkRunFields() {
        let check = apiCheckRunToRefCheck(apiCheckRun(id: 9, name: "build", checkSuite: 42))
        #expect(check.appName == "GitHub Actions")
        #expect(check.checkSuiteID == 42)
        #expect(check.htmlURL == "https://github.com/octocat/hello/runs/9")
    }

    @Test("a rerun replaces the run it reran; push and pull request runs, and other apps' runs, stay apart")
    func latestCheckRuns() {
        let runs = [
            apiCheckRun(id: 1, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 2, name: "build", checkSuite: 101),
            apiCheckRun(id: 3, name: "build", checkSuite: 102, pullRequests: []),
            apiCheckRun(id: 4, name: "build", app: "Travis CI", checkSuite: 50),
            apiCheckRun(id: 5, name: "test", checkSuite: 100),
        ]
        #expect(getLatestCheckRunsById(runs).map(\.id) == [2, 3, 4, 5])
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
        ]
        let suites = [
            APICheckSuite(id: 1, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 1)),
            APICheckSuite(id: 2, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 2)),
            APICheckSuite(id: 3, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: createdAt(daysAgo: 31)),
            APICheckSuite(id: 4, rerequestable: true, runsRerequestable: true, status: .inProgress, createdAt: createdAt(daysAgo: 1)),
        ]

        let all = rerunPlan(checks, failedOnly: false, checkSuites: suites, now: now)
        #expect(all.rerunnable.map(\.id) == [1, 2])
        #expect(all.nonRerunnable.map(\.id) == [3, 4, 5])
        #expect(all.warning != nil)
        #expect(all.dependentsMessage(allChecks: checks) != nil)

        let failed = rerunPlan(checks, failedOnly: true, checkSuites: suites, now: now)
        #expect(failed.rerunnable.map(\.id) == [1])
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
