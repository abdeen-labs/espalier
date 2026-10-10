// Ported from desktop/app/test/unit/repo-rules-test.ts
// Plus tests of the rest of BranchRules.swift, finding a branch name, the
// branch name check, and the composer's rule warnings and gate. Push
// control is checked through the branch protection it decides
// (BranchProtectionTests).

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private let creationRule = APIRepoRule(rulesetID: 1, type: .creation)

private let creationBypassAlwaysRule = APIRepoRule(rulesetID: 2, type: .creation)

private let creationBypassPullRequestsOnlyRule = APIRepoRule(rulesetID: 3, type: .creation)

private let commitMessagePatternStartsWithRule = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "abc", operator: .startsWith)
)

private let commitMessagePatternStartsWithBypassRule = APIRepoRule(
    rulesetID: 2,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "abc", operator: .startsWith)
)

private let commitMessagePatternSpecialCharactersRule = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    // API response is backslash escaped like this
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: #"(a.b.c.)|(d+)\d"#, operator: .startsWith)
)

private let commitMessagePatternEndsWithRule = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: true, pattern: "end", operator: .endsWith)
)

private let commitMessagePatternContainsRule = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: true, pattern: "con", operator: .contains)
)

private let commitMessagePatternRegexRule1 = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "(a.b.c.)|(d+)", operator: .regexMatch)
)

private let commitMessagePatternRegexRule2 = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    // API response is backslash escaped like this
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: #"^\A(d|e)oo\d$"#, operator: .regexMatch)
)

private let commitMessagePatternRegexMultiLineRule = APIRepoRule(
    rulesetID: 1,
    type: .commitMessagePattern,
    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "(?m)^foo", operator: .regexMatch)
)

private let rulesets: [Int: APIRepoRuleset] = [
    1: APIRepoRuleset(id: 1, currentUserCanBypass: .never),
    2: APIRepoRuleset(id: 2, currentUserCanBypass: .always),
]

private func parse(_ rules: [APIRepoRule], gpgSign: Bool = false) async -> RepoRulesInfo {
    await parseRepoRules(rules, rulesets) { gpgSign }
}

private func validateMetadataRules(
    _ rules: RepoRulesMetadataFailures,
    _ status: RepoRulesMetadataStatus,
    _ bypassesExpected: Int,
    _ failuresExpected: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(rules.status == status, sourceLocation: sourceLocation)
    #expect(rules.bypassed.count == bypassesExpected, sourceLocation: sourceLocation)
    #expect(rules.failed.count == failuresExpected, sourceLocation: sourceLocation)
}

@Suite("await parseRepoRules")
struct ParseRepoRulesTests {
    @Test("the creation rule is enforced, bypassed, or not, by its rulesets' bypass modes", arguments: [
        // the creation rule references ruleset ID 1, which has a bypass of 'never'
        NamedCase("cannot bypass when bypass is \"never\"", [
            (rules: [creationRule], expected: RepoRuleEnforced.enforced),
        ]),
        // the creationBypass rule references ruleset ID 2, which has a bypass of 'always'
        NamedCase("can bypass when bypass is \"always\"", [
            (rules: [creationBypassAlwaysRule], expected: .bypass),
        ]),
        NamedCase("cannot bypass when at least one bypass mode is \"never\" or \"pull_requests_only\"", [
            (rules: [creationRule, creationBypassAlwaysRule], expected: .enforced),
            (rules: [creationRule, creationBypassPullRequestsOnlyRule], expected: .enforced),
        ]),
    ])
    func creationRestricted(_ testCase: NamedCase<[(rules: [APIRepoRule], expected: RepoRuleEnforced)]>) async {
        for (rules, expected) in testCase.value {
            let result = await parse(rules)
            #expect(result.creationRestricted == expected)
        }
    }
}

@Suite("repo metadata rules")
struct RepoMetadataRulesTests {
    @Suite("startsWith rule")
    struct StartsWith {
        @Test("shows no rules and passes everything when no rules are provided")
        func noRules() async {
            let repoRulesInfo = await parse([])
            #expect(!repoRulesInfo.commitMessagePatterns.hasRules)

            let failedRules = repoRulesInfo.commitMessagePatterns.getFailedRules("abc")
            validateMetadataRules(failedRules, .pass, 0, 0)
        }

        @Test("has correct matching logic for StartsWith rule")
        func matching() async {
            let repoRulesInfo = await parse([commitMessagePatternStartsWithRule])
            #expect(repoRulesInfo.commitMessagePatterns.hasRules)

            let failedRules = repoRulesInfo.commitMessagePatterns.getFailedRules("def")
            validateMetadataRules(failedRules, .fail, 0, 1)
            #expect(failedRules.failed[0].description == #"must start with "abc""#)
        }

        @Test("has correct bypass logic for StartsWith rule")
        func bypass() async {
            let repoRulesInfo = await parse([commitMessagePatternStartsWithBypassRule])

            let failedRules = repoRulesInfo.commitMessagePatterns.getFailedRules("def")
            validateMetadataRules(failedRules, .bypass, 1, 0)
            #expect(failedRules.bypassed[0].description == #"must start with "abc""#)
        }

        @Test("has correct logic when bypassed rule is included with non-bypassed rule")
        func mixed() async {
            let repoRulesInfo = await parse([commitMessagePatternStartsWithRule, commitMessagePatternStartsWithBypassRule])

            let failedRules = repoRulesInfo.commitMessagePatterns.getFailedRules("def")
            validateMetadataRules(failedRules, .fail, 1, 1)
            #expect(failedRules.bypassed[0].description == #"must start with "abc""#)
            #expect(failedRules.failed[0].description == #"must start with "abc""#)
        }

        @Test("escapes special characters and otherwise handles regex properly")
        func specialCharacters() async {
            let repoRulesInfo = await parse([commitMessagePatternSpecialCharactersRule])

            // if the . in the pattern is interpreted as a regex special character, this will pass
            let rules1 = repoRulesInfo.commitMessagePatterns.getFailedRules("aabbcc")
            #expect(rules1.status == .fail)

            let rules2 = repoRulesInfo.commitMessagePatterns.getFailedRules("dd")
            #expect(rules2.status == .fail)

            let passedRules = repoRulesInfo.commitMessagePatterns.getFailedRules(#"(a.b.c.)|(d+)\d"#)
            #expect(passedRules.status == .pass)
        }
    }

    // The "endsWith rule" and "contains rule" blocks, one test each.
    @Test("a negated rule fails a message that matches it and passes one that doesn't", arguments: [
        NamedCase("has correct matching logic for negated EndsWith rule", (
            rule: commitMessagePatternEndsWithRule,
            failing: "end",
            failure: #"must not end with "end""#,
            passing: "abc"
        )),
        NamedCase("has correct matching logic for Contains rule", (
            rule: commitMessagePatternContainsRule,
            failing: "fooconbar",
            failure: #"must not contain "con""#,
            passing: "foobar"
        )),
    ])
    func negated(_ testCase: NamedCase<(rule: APIRepoRule, failing: String, failure: String, passing: String)>) async {
        let (rule, failing, failure, passing) = testCase.value
        let repoRulesInfo = await parse([rule])

        let failedRules = repoRulesInfo.commitMessagePatterns.getFailedRules(failing)
        validateMetadataRules(failedRules, .fail, 0, 1)
        #expect(failedRules.failed[0].description == failure)

        let passedRules = repoRulesInfo.commitMessagePatterns.getFailedRules(passing)
        validateMetadataRules(passedRules, .pass, 0, 0)
    }

    @Suite("regex rule")
    struct Regex {
        @Test("has correct matching logic for RegexMatch rule")
        func regex() async {
            let repoRulesInfo = await parse([commitMessagePatternRegexRule1, commitMessagePatternRegexRule2])

            let results1 = repoRulesInfo.commitMessagePatterns.getFailedRules("doo5")
            validateMetadataRules(results1, .pass, 0, 0)

            let results2 = repoRulesInfo.commitMessagePatterns.getFailedRules("afbgch")
            validateMetadataRules(results2, .fail, 0, 1)
            #expect(results2.failed[0].description == #"must match the regular expression "^\A(d|e)oo\d$""#)

            let results3 = repoRulesInfo.commitMessagePatterns.getFailedRules("eoo4")
            validateMetadataRules(results3, .fail, 0, 1)
            #expect(results3.failed[0].description == #"must match the regular expression "(a.b.c.)|(d+)""#)

            let results4 = repoRulesInfo.commitMessagePatterns.getFailedRules("fgsa")
            validateMetadataRules(results4, .fail, 0, 2)
            #expect(results4.failed[0].description == #"must match the regular expression "(a.b.c.)|(d+)""#)
            #expect(results4.failed[1].description == #"must match the regular expression "^\A(d|e)oo\d$""#)
        }

        @Test("has correct matching logic for multi-line data")
        func multiLine() async {
            let repoRulesInfo = await parse([commitMessagePatternRegexMultiLineRule])

            let results1 = repoRulesInfo.commitMessagePatterns.getFailedRules("first line\nfoo")
            validateMetadataRules(results1, .pass, 0, 0)

            let results2 = repoRulesInfo.commitMessagePatterns.getFailedRules("asdf\nbar")
            validateMetadataRules(results2, .fail, 0, 1)
            #expect(results2.failed[0].description == #"must match the regular expression "(?m)^foo""#)
        }
    }
}

@Suite("getEnforcedRuleDescriptions")
struct EnforcedRuleDescriptionsTests {
    // Ruleset 1 has bypass 'never' (enforced), ruleset 2 'always' (bypass,
    // still evaluated by github.com).
    @Test("returns descriptions for both enforced and bypass-able rules together")
    func descriptions() async {
        let repoRulesInfo = await parse([
            commitMessagePatternStartsWithRule,
            commitMessagePatternStartsWithBypassRule,
            commitMessagePatternEndsWithRule,
        ])
        #expect(getEnforcedRuleDescriptions(repoRulesInfo.commitMessagePatterns.getRules()) == [
            #"must start with "abc""#,
            #"must start with "abc""#,
            #"must not end with "end""#,
        ])
    }
}

// MARK: Espalier's tests

@Suite("Repository rules")
struct RepositoryRulesTests {
    @Test("rule types map to desktop's flags; a signed-commits rule needs no warning when commits are signed")
    func ruleTypes() async {
        let rules = [
            APIRepoRule(rulesetID: 1, type: .update),
            APIRepoRule(rulesetID: 2, type: .requiredSignatures),
            APIRepoRule(rulesetID: 2, type: .pullRequest),
            APIRepoRule(rulesetID: 1, type: APIRepoRuleType(rawValue: "non_fast_forward")),
            APIRepoRule(rulesetID: 9, type: .creation),
        ]
        let info = await parse(rules)
        #expect(info.basicCommitWarning == .enforced)
        #expect(info.signedCommitsRequired == .bypass)
        #expect(info.pullRequestRequired == .bypass)
        // Ruleset 9 isn't known: its rule doesn't count.
        #expect(info.creationRestricted == .notEnforced)

        var asked = 0
        let signed = await parseRepoRules(rules + [APIRepoRule(rulesetID: 1, type: .requiredSignatures)], rulesets) {
            asked += 1
            return true
        }
        #expect(signed.signedCommitsRequired == .notEnforced)
        #expect(asked == 1)
    }

    @Test("RE2 patterns match as GitHub's do: $ is the end of the text, \\d and . are ASCII and line-bound")
    func re2Semantics() async {
        func failures(_ pattern: String, _ text: String) async -> RepoRulesMetadataStatus {
            let info = await parse([APIRepoRule(
                rulesetID: 1,
                type: .commitMessagePattern,
                parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: pattern, operator: .regexMatch)
            )])
            return info.commitMessagePatterns.getFailedRules(text).status
        }
        // A commit message ends with a line break; RE2's $ doesn't match before it.
        #expect(await failures("done$", "all done\n") == .fail)
        #expect(await failures("done$", "all done") == .pass)
        #expect(await failures("(?m)done$", "all done\n") == .pass)
        // \d is ASCII only.
        #expect(await failures(#"^\d+$"#, "\u{0663}") == .fail)
        #expect(await failures(#"^\d+$"#, "42") == .pass)
        // . doesn't cross a line break, but crosses a carriage return.
        #expect(await failures("^a.b$", "a\rb") == .pass)
        #expect(await failures("^a.b$", "a\nb") == .fail)
        #expect(await failures("(?s)^a.b$", "a\nb") == .pass)
        // Named groups in RE2's spelling.
        #expect(await failures(#"^(?P<kind>feat|fix): "#, "feat: x") == .pass)
        // Character classes keep their contents.
        #expect(await failures("^[$.]+$", "$.$") == .pass)
        #expect(await failures(#"^[\d.]+$"#, "1.2") == .pass)
    }

    @Test("translates RE2 patterns to ICU")
    func translation() {
        #expect(translateRE2Pattern("a$") == #"a\z"#)
        #expect(translateRE2Pattern("(?m)a$") == "(?m)a$")
        #expect(translateRE2Pattern("a.b") == #"a[^\n]b"#)
        #expect(translateRE2Pattern("(?s)a.b") == "(?s)a.b")
        #expect(translateRE2Pattern(#"\d\w\s"#) == #"[0-9][0-9A-Za-z_][\t\n\f\r ]"#)
        #expect(translateRE2Pattern(#"[\d$.]"#) == #"[0-9$.]"#)
        #expect(translateRE2Pattern(#"\Q.$\E"#) == #"\Q.$\E"#)
        #expect(translateRE2Pattern("(?P<x>a)") == "(?<x>a)")
        #expect(translateRE2Pattern("[]a]$") == #"[]a]\z"#)
        #expect(translateRE2Pattern("[[:alpha:]]+") == "[[:alpha:]]+")
    }

    @Test("a pattern ICU can't compile passes rather than blocking the commit")
    func uncompilablePattern() async {
        let info = await parse([APIRepoRule(
            rulesetID: 1,
            type: .commitMessagePattern,
            parameters: APIRepoRuleMetadataParameters(name: "", negate: true, pattern: "(unclosed", operator: .regexMatch)
        )])
        #expect(info.commitMessagePatterns.getFailedRules("anything").status == .pass)
    }

    @Test("protection is looked up for the upstream's name when the remote is the GitHub repository's")
    func remoteBranchName() {
        let gitHubRepository = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello")
        let tracking = ModelFixtures.branch("local-name", upstream: "origin/remote-name")
        let origin = Remote(name: "origin", url: "https://github.com/octocat/hello.git")
        let fork = Remote(name: "origin", url: "https://github.com/someone/hello.git")
        #expect(findRemoteBranchName(.valid(branch: tracking), origin, gitHubRepository) == "remote-name")
        #expect(findRemoteBranchName(.valid(branch: tracking), fork, gitHubRepository) == "local-name")
        #expect(findRemoteBranchName(.valid(branch: tracking), nil, gitHubRepository) == "local-name")
        #expect(findRemoteBranchName(.detached(currentSha: "abc"), origin, gitHubRepository) == nil)
    }

    @Test("rules apply on GitHub.com, except to the user's own private repositories on a free plan")
    func rulesLogic() {
        let mine = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello")
        let privateMine = GitHubRepository(name: "hello", owner: mine.owner, dbID: 1, isPrivate: true)
        let enterprise = ModelFixtures.gitHubRepository(endpoint: "https://github.example.com/api/v3")
        let free = dotComAccount(login: "octocat")
        let pro = Account(login: "octocat", endpoint: dotComEndpoint, token: "t", emails: [], avatarURL: "", id: 1, name: "", plan: "pro")
        let other = dotComAccount(login: "hubot")
        #expect(useRepoRulesLogic(free, mine))
        #expect(!useRepoRulesLogic(free, privateMine))
        #expect(useRepoRulesLogic(pro, privateMine))
        #expect(useRepoRulesLogic(other, privateMine))
        #expect(!useRepoRulesLogic(free, enterprise))
        #expect(!useRepoRulesLogic(nil, mine))
        #expect(!useRepoRulesLogic(free, nil))
    }

    @Test("a branch name is an error when a rule the user can't bypass fails, a warning when only bypassable ones do")
    func branchNameCheck() async {
        let namePattern = APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "feature/", operator: .startsWith)
        let enforcedName = await parse([APIRepoRule(rulesetID: 1, type: .branchNamePattern, parameters: namePattern)])
        let bypassName = await parse([APIRepoRule(rulesetID: 2, type: .branchNamePattern, parameters: namePattern)])
        let bypassCreation = await parse([creationBypassAlwaysRule])
        let mixed = await parse([
            APIRepoRule(rulesetID: 1, type: .branchNamePattern, parameters: namePattern),
            creationBypassAlwaysRule,
        ])

        #expect(branchNameRuleError("feature/x", enforcedName) == nil)
        #expect(branchNameRuleError("fix", enforcedName) == BranchNameRuleError(
            message: "Repository rules don't allow a branch named \u{201C}fix\u{201D}.",
            isWarning: false
        ))
        #expect(branchNameRuleError("fix", bypassName) == BranchNameRuleError(
            message: "Repository rules restrict a branch named \u{201C}fix\u{201D}, but you can bypass them.",
            isWarning: true
        ))
        // A creation rule the user can bypass warns too.
        #expect(branchNameRuleError("anything", bypassCreation)?.isWarning == true)
        // Not an error: the rule the user can't bypass passes.
        #expect(branchNameRuleError("feature/x", mixed)?.isWarning == true)
    }

    @Test("the composer shows one warning, in desktop's priority, errors before bypasses")
    func commitWarnings() async {
        let gitHubRepository = ModelFixtures.gitHubRepository(name: "hello", permissions: .write)
        var inputs = CommitRuleInputs(
            gitHubRepository: gitHubRepository,
            rulesEnabled: true,
            rules: RepoRulesInfo(),
            currentBranchProtected: false,
            branch: "main",
            aheadBehind: AheadBehind(ahead: 0, behind: 0),
            fileCount: 1
        )
        #expect(commitRuleWarning(inputs) == nil)

        inputs.rules = await parse([
            APIRepoRule(rulesetID: 2, type: .update),
            APIRepoRule(rulesetID: 1, type: .requiredSignatures),
        ])
        #expect(commitRuleWarning(inputs) == .signedCommitsRequired(branch: "main", canBypass: false))
        #expect(commitRuleWarning(inputs)?.message == "Repository rules require signed commits on main.")
        #expect(commitRuleWarning(inputs)?.isError == true)
        #expect(commitRuleWarning(inputs)?.action == nil)

        inputs.rules = await parse([APIRepoRule(rulesetID: 2, type: .update)])
        #expect(commitRuleWarning(inputs) == .pushRestricted(branch: "main", canBypass: true))
        #expect(commitRuleWarning(inputs)?.message == "Repository rules restrict pushing to main, but you can bypass them.")
        #expect(commitRuleWarning(inputs)?.isError == false)

        inputs.rules = await parse([APIRepoRule(rulesetID: 1, type: .pullRequest)])
        #expect(commitRuleWarning(inputs) == .pushRestricted(branch: "main", canBypass: false))
        #expect(commitRuleWarning(inputs)?.message == "Repository rules don't allow pushing to main.")
        #expect(commitRuleWarning(inputs)?.action == .switchBranches)

        // An unpublished branch whose name fails: publishing comes first.
        inputs.aheadBehind = nil
        inputs.rules = await parse([creationRule, APIRepoRule(rulesetID: 1, type: .pullRequest)])
        #expect(commitRuleWarning(inputs) == .publishRestricted(branch: "main", canBypass: false))
        #expect(commitRuleWarning(inputs)?.message == "Repository rules don't allow publishing main.")

        // A protected branch, then no write access, outrank the rules.
        inputs.currentBranchProtected = true
        #expect(commitRuleWarning(inputs) == .branchProtected(branch: "main"))
        #expect(commitRuleWarning(inputs)?.message == "main is a protected branch.")
        #expect(commitRuleWarning(inputs)?.action == .switchBranches)
        inputs.gitHubRepository = ModelFixtures.gitHubRepository(name: "hello", permissions: .read)
        #expect(commitRuleWarning(inputs) == .noWriteAccess(repositoryName: "hello"))
        #expect(commitRuleWarning(inputs)?.message == "You don't have write access to hello.")
        #expect(commitRuleWarning(inputs)?.action == .createFork)

        // Without changes only the rules warn.
        inputs.fileCount = 0
        #expect(commitRuleWarning(inputs) == .publishRestricted(branch: "main", canBypass: false))

        // Without rules logic, nothing.
        inputs.rulesEnabled = false
        #expect(commitRuleWarning(inputs) == nil)
    }

    @Test("the commit gate stops what can't be pushed, and lets what can be bypassed through")
    func commitGate() async {
        let messagePattern = APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "feat", operator: .startsWith)
        var inputs = CommitRuleInputs(
            gitHubRepository: ModelFixtures.gitHubRepository(),
            rulesEnabled: true,
            rules: await parse([APIRepoRule(rulesetID: 2, type: .update), APIRepoRule(rulesetID: 2, type: .commitMessagePattern, parameters: messagePattern)]),
            currentBranchProtected: false,
            branch: "main",
            aheadBehind: AheadBehind(ahead: 0, behind: 0),
            fileCount: 1
        )
        #expect(repoRuleCommitFailure(inputs, message: "fix things\n", authorEmail: "a@example.com") == nil)

        inputs.rules = await parse([APIRepoRule(rulesetID: 1, type: .commitMessagePattern, parameters: messagePattern)])
        #expect(repoRuleCommitFailure(inputs, message: "fix things\n", authorEmail: nil) == "This commit message fails 1 rule.")
        #expect(repoRuleCommitFailure(inputs, message: "feat: things\n", authorEmail: nil) == nil)

        let emailPattern = APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "@example.com", operator: .endsWith)
        inputs.rules = await parse([APIRepoRule(rulesetID: 1, type: .commitAuthorEmailPattern, parameters: emailPattern)])
        #expect(repoRuleCommitFailure(inputs, message: "x\n", authorEmail: "me@elsewhere.org")
            == "Your commit email, me@elsewhere.org, fails 1 rule.")
        #expect(repoRuleCommitFailure(inputs, message: "x\n", authorEmail: "me@example.com") == nil)

        inputs.rules = await parse([creationRule])
        #expect(repoRuleCommitFailure(inputs, message: "x\n", authorEmail: nil) == nil)
        inputs.aheadBehind = nil
        #expect(repoRuleCommitFailure(inputs, message: "x\n", authorEmail: nil) == "Repository rules don't allow publishing main.")

        inputs.rulesEnabled = false
        #expect(repoRuleCommitFailure(inputs, message: "x\n", authorEmail: nil) == nil)
    }

    @Test("failure lists summarize as desktop's")
    func failureSummary() {
        var failures = RepoRulesMetadataFailures()
        #expect(failures.summary(leadingText: "This commit message") == nil)
        failures.bypassed = [RepoRulesMetadataFailure(description: "x", rulesetId: 1)]
        #expect(failures.summary(leadingText: "This commit message") == "This commit message fails 1 rule, but you can bypass it.")
        failures.bypassed.append(RepoRulesMetadataFailure(description: "y", rulesetId: 2))
        #expect(failures.summary(leadingText: "This commit message") == "This commit message fails 2 rules, but you can bypass them.")
        failures.failed = [RepoRulesMetadataFailure(description: "z", rulesetId: 3)]
        #expect(failures.summary(leadingText: "This commit message") == "This commit message fails 3 rules.")
    }
}
