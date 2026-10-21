// The current branch's protection and rules against a mock GitHub, the
// commit gate that refuses what the rules won't let be pushed, the branch
// name check, and clearing.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// A rule as `GET /repos/{owner}/{repo}/rules/branches/{branch}` returns it.
private func rule(_ type: String, ruleset: Int, operator: String? = nil, pattern: String? = nil) -> JSONValue {
    var rule: [String: JSONValue] = ["type": .string(type), "ruleset_id": .number(Double(ruleset))]
    if let `operator`, let pattern {
        rule["parameters"] = ["operator": .string(`operator`), "pattern": .string(pattern), "negate": false, "name": ""]
    }
    return .object(rule)
}

@Suite("Branch protection and rules", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchProtectionTests {
    /// Mocks rulesets 1 (never bypassed) and 2 (always), and `rules` for
    /// the main branch.
    private static func mockRules(_ gitHub: MockGitHub, main rules: [JSONValue]) {
        gitHub.on("GET", "/repos/octocat/hello/rulesets", respond: .json([["id": 1], ["id": 2]]))
        gitHub.on("GET", "/repos/octocat/hello/rulesets/1", respond: .json(["id": 1, "current_user_can_bypass": "never"]))
        gitHub.on("GET", "/repos/octocat/hello/rulesets/2", respond: .json(["id": 2, "current_user_can_bypass": "always"]))
        gitHub.on("GET", "/repos/octocat/hello/rules/branches/main", respond: .json(.array(rules)))
    }

    @Test("loads whether the current branch is protected and which rules apply to it")
    func refresh() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/branches/main/push_control", respond: .json(pushControl(allowActor: false)))
            Self.mockRules(gitHub, main: [rule("update", ruleset: 1), rule("required_signatures", ruleset: 2)])
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshBranchProtection()

        #expect(gitHub.currentBranchProtected)
        let rules = try #require(gitHub.repoRules)
        #expect(rules.basicCommitWarning == .enforced)
        #expect(rules.signedCommitsRequired == .bypass)
        #expect(gitHub.repoRulesEnabled)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/branches/main/push_control").last?.header("Accept")
            == "application/vnd.github.phandalin-preview")
        // No changes: the protected branch doesn't warn; the rules do.
        #expect(gitHub.commitWarning == .pushRestricted(branch: "main", canBypass: false))
        try fixture.harness.write("new.txt", "new\n", in: fixture.local)
        await fixture.model.refresh(.status, reason: .user)
        #expect(gitHub.commitWarning == .branchProtected(branch: "main"))

        // The rulesets are fetched once.
        await gitHub.refreshBranchProtection()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/rulesets/1").count == 1)

        gitHub.clearBranchProtection()
        #expect(!gitHub.currentBranchProtected)
        #expect(gitHub.repoRules == nil)
        await fixture.settle()
    }

    @Test("without write access the branch counts as unprotected, and GitHub isn't asked")
    func readOnly() async throws {
        let fixture = try await makeGitHubFixture(permissions: APIRepositoryPermissions(admin: false, push: false, pull: true)) { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/branches/main/push_control", respond: .json(pushControl(allowActor: false)))
        }
        await fixture.model.gitHub.refreshBranchProtection()
        #expect(!fixture.model.gitHub.currentBranchProtected)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/branches/main/push_control").isEmpty)
        await fixture.settle()
    }

    @Test("rules aren't asked for on the user's own private repository on a free plan")
    func freePrivate() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: APIFullRepository(
                repository: apiRepository(owner: "octocat", name: "hello", isPrivate: true),
                permissions: APIRepositoryPermissions(admin: true, push: true, pull: true)
            )))
        }
        await fixture.model.gitHub.refreshBranchProtection()
        #expect(!fixture.model.gitHub.repoRulesEnabled)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/rulesets").isEmpty)
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/branches/main/push_control").count >= 1)
        await fixture.settle()
    }

    @Test("the commit gate refuses a commit the rules won't let be pushed, before anything else")
    func commitGate() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            Self.mockRules(gitHub, main: [rule("commit_message_pattern", ruleset: 1, operator: "starts_with", pattern: "feat")])
        }
        let model = fixture.model
        await model.gitHub.refreshBranchProtection()
        try fixture.harness.write("new.txt", "new\n", in: fixture.local)
        await model.refresh(.status, reason: .user)

        model.commit.draft.summary = "fix the thing"
        let error = await #expect(throws: OperationError.self) {
            try await model.commit.commit()
        }
        #expect(preconditionMessage(error) != nil)
        #expect(await model.gitHub.commitMessageRuleFailures().status == .fail)

        model.commit.draft.summary = "feat: the thing"
        #expect(await model.gitHub.commitMessageRuleFailures().status == .pass)
        let commit = try await model.commit.commit()
        #expect(model.gitState.tip.branch?.tip.sha == commit.sha)
        #expect(model.gitHub.commitMessageRules.map(\.humanDescription) == [#"must start with "feat""#])
        await fixture.settle()
    }

    @Test("rules the user can bypass don't stop the commit")
    func bypassableGate() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            Self.mockRules(gitHub, main: [
                rule("update", ruleset: 2),
                rule("commit_message_pattern", ruleset: 2, operator: "starts_with", pattern: "feat"),
            ])
        }
        let model = fixture.model
        await model.gitHub.refreshBranchProtection()
        try fixture.harness.write("new.txt", "new\n", in: fixture.local)
        await model.refresh(.status, reason: .user)
        #expect(model.gitHub.commitWarning == .pushRestricted(branch: "main", canBypass: true))

        model.commit.draft.summary = "fix the thing"
        _ = try await model.commit.commit()
        await fixture.settle()
    }

    @Test("a new branch's protection loads when the selected repository switches to it")
    func newBranch() async throws {
        let fixture = try await makeGitHubFixture(select: true) { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/branches/topic/push_control", respond: .json(pushControl(reviews: 1)))
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshBranchProtection()
        #expect(!gitHub.currentBranchProtected)

        _ = try await fixture.model.branches.createBranch("topic", startPoint: nil, checkout: true)
        await fixture.settle()
        #expect(fixture.model.gitState.tip.branch?.name == "topic")
        #expect(gitHub.currentBranchProtected)

        // Checked out outside Espalier: a detached HEAD, then main. Reloading
        // only between two branches would leave main with topic's state.
        let mainRequests = fixture.gitHub.requests("GET", "/repos/octocat/hello/branches/main/push_control").count
        try await runGit(["checkout", "--detach"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        await fixture.settle()
        try await runGit(["checkout", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        await fixture.settle()
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/branches/main/push_control").count == mainRequests + 1)
        #expect(!gitHub.currentBranchProtected)
        await fixture.settle()
    }

    @Test("a refresh that started before the protection was cleared doesn't apply")
    func clearedDuringRefresh() async throws {
        let gate = MockResponseGate()
        let fixture = try await makeGitHubFixture()
        fixture.gitHub.on("GET", "/repos/octocat/hello/branches/main/push_control") { _ in
            gate.wait()
            // Required status checks are a merge requirement: no direct pushes.
            return .json(pushControl(requiredStatusChecks: ["ci"]))
        }
        let gitHub = fixture.model.gitHub
        let refresh = Task { await gitHub.refreshBranchProtection() }
        try await gate.waitForArrival()
        gitHub.clearBranchProtection()
        gate.open()
        await refresh.value
        #expect(!gitHub.currentBranchProtected)

        await gitHub.refreshBranchProtection()
        #expect(gitHub.currentBranchProtected)
        await fixture.settle()
    }

    @Test("the New Branch sheet's name check asks for the name's rules")
    func branchNameCheck() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            Self.mockRules(gitHub, main: [])
            gitHub.on("GET", "/repos/octocat/hello/rules/branches/fix", respond: .json([
                rule("branch_name_pattern", ruleset: 1, operator: "starts_with", pattern: "feature/"),
            ]))
            gitHub.on("GET", "/repos/octocat/hello/rules/branches/try", respond: .json([rule("creation", ruleset: 2)]))
            gitHub.on("GET", "/repos/octocat/hello/rules/branches/feature%2Fx", respond: .json([]))
        }
        let gitHub = fixture.model.gitHub
        #expect(await gitHub.checkBranchNameRules("fix")?.isWarning == false)
        #expect(await gitHub.checkBranchNameRules("try")?.isWarning == true)
        #expect(await gitHub.checkBranchNameRules("feature/x") == nil)
        #expect(await gitHub.checkBranchNameRules("") == nil)
        await fixture.settle()
    }
}
