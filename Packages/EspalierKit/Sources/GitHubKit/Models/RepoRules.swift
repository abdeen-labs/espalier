// Ported from desktop/app/src/models/repo-rules.ts

/// Whether a rule is enforced for the current user.
public enum RepoRuleEnforced: Sendable, Hashable, ExpressibleByBooleanLiteral {
    case notEnforced
    case enforced
    /// The rule applies, but the user can bypass it.
    case bypass

    public init(booleanLiteral value: Bool) {
        self = value ? .enforced : .notEnforced
    }
}

public enum RepoRulesMetadataStatus: String, Sendable, Hashable {
    case pass
    case fail
    case bypass
}

public struct RepoRulesMetadataFailure: Sendable, Hashable {
    public var description: String
    public var rulesetId: Int

    public init(description: String, rulesetId: Int) {
        self.description = description
        self.rulesetId = rulesetId
    }
}

public struct RepoRulesMetadataFailures: Sendable, Hashable {
    public var failed: [RepoRulesMetadataFailure] = []
    public var bypassed: [RepoRulesMetadataFailure] = []

    public init(failed: [RepoRulesMetadataFailure] = [], bypassed: [RepoRulesMetadataFailure] = []) {
        self.failed = failed
        self.bypassed = bypassed
    }

    /// Returns the status of the rule based on its failures.
    /// 'pass' means all rules passed, 'bypass' means some rules failed
    /// but the user can bypass all of the failures, and 'fail' means
    /// at least one rule failed that the user cannot bypass.
    public var status: RepoRulesMetadataStatus {
        if failed.isEmpty {
            if bypassed.isEmpty {
                return .pass
            }

            return .bypass
        }

        return .fail
    }
}

/// Function that determines whether the provided string matches the rule.
public typealias RepoRulesMetadataMatcher = @Sendable (_ toMatch: String) -> Bool

public struct RepoRulesMetadataRule: Sendable {
    /// Whether this rule is enforced for the current user.
    public var enforced: RepoRuleEnforced

    /// Function that determines whether the provided string matches the rule.
    public var matcher: RepoRulesMetadataMatcher

    /// Human-readable description of the rule. For example, a 'starts_with'
    /// rule with the pattern 'abc' that is negated would have a description
    /// of 'must not start with "abc"'.
    public var humanDescription: String

    /// ID of the ruleset this rule is configured in.
    public var rulesetId: Int

    public init(
        enforced: RepoRuleEnforced,
        matcher: @escaping RepoRulesMetadataMatcher,
        humanDescription: String,
        rulesetId: Int
    ) {
        self.enforced = enforced
        self.matcher = matcher
        self.humanDescription = humanDescription
        self.rulesetId = rulesetId
    }
}

/// Metadata restrictions for a specific type of rule, as multiple can
/// be configured at once and all apply to the branch.
public struct RepoRulesMetadataRules: Sendable {
    private var rules: [RepoRulesMetadataRule] = []

    public init() {}

    public mutating func push(_ rule: RepoRulesMetadataRule?) {
        guard let rule else {
            return
        }

        rules.append(rule)
    }

    /// Whether any rules are configured.
    public var hasRules: Bool {
        !rules.isEmpty
    }

    /// Gets an object containing arrays of human-readable rules that
    /// fail to match the provided input string. If the returned object
    /// contains only empty arrays, then all rules pass.
    public func getFailedRules(_ toMatch: String) -> RepoRulesMetadataFailures {
        var failures = RepoRulesMetadataFailures()
        for rule in rules where !rule.matcher(toMatch) {
            let failure = RepoRulesMetadataFailure(description: rule.humanDescription, rulesetId: rule.rulesetId)
            if rule.enforced == .bypass {
                failures.bypassed.append(failure)
            } else {
                failures.failed.append(failure)
            }
        }

        return failures
    }

    /// Returns a copy of the underlying rules. Intended for callers that need
    /// to inspect or filter rules beyond the matching logic provided by
    /// `getFailedRules`.
    public func getRules() -> [RepoRulesMetadataRule] {
        rules
    }
}

/// Parsed repo rule info
public struct RepoRulesInfo: Sendable {
    /// Many rules are not handled in a special way, they
    /// instead just display a warning to the user when they're
    /// about to commit. They're lumped together into this flag
    /// for simplicity. See the `parseRepoRules` function for
    /// the full list.
    public var basicCommitWarning: RepoRuleEnforced = false

    /// If true, the branch's name conflicts with a rule and
    /// cannot be created.
    public var creationRestricted: RepoRuleEnforced = false

    /// Whether signed commits are required. `parseRepoRules` will
    /// set this to `false` if the user has commit signing configured.
    public var signedCommitsRequired: RepoRuleEnforced = false

    public var pullRequestRequired: RepoRuleEnforced = false
    public var commitMessagePatterns = RepoRulesMetadataRules()
    public var commitAuthorEmailPatterns = RepoRulesMetadataRules()
    public var committerEmailPatterns = RepoRulesMetadataRules()
    public var branchNamePatterns = RepoRulesMetadataRules()

    public init() {}
}
