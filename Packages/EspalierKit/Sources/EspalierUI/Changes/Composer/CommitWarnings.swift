// The composer's warning, one at a time. `gitHub.commitWarning` decides which
// warning shows and words it (in order: no write access, a protected branch,
// then the rules that would stop publishing, require signed commits, or stop
// pushing, enforced ones before bypassable ones); this file links "Repository
// rules" to the branch's rulesets, sets the name in bold, and adds the
// warning's action ("create a fork", "switch branches") as a link. The
// commit message's rule hint reads `commitMessageRuleFailures()`.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The warning above the commit button: the repository's commit warning,
/// with the branch's rulesets for a rules warning.
nonisolated public struct CommitWarning: Sendable, Equatable {
    /// Which warning, and its words.
    public var rule: CommitRuleWarning
    /// The branch's rulesets on GitHub, for a rules warning.
    public var rulesURL: URL?

    public init(_ rule: CommitRuleWarning, rulesURL: URL? = nil) {
        self.rule = rule
        self.rulesURL = rulesURL
    }

    /// Whether the warning is an error: rules the user can't bypass.
    public var isError: Bool {
        rule.isError
    }

    /// The warning's text, with its links: "Repository rules" to the
    /// rulesets, and the action ("create a fork", "switch branches"). The
    /// branch or repository is bold, found where the sentence puts it, and
    /// never read as Markdown.
    public var message: AttributedString {
        var text = AttributedString(rule.message)
        if let (before, after) = rule.textAroundName {
            var lead = AttributedString(before)
            if let rulesURL, before.hasPrefix(Self.rulesPhrase) {
                lead = .composerText(.link(Self.rulesPhrase, rulesURL), .plain(String(before.dropFirst(Self.rulesPhrase.count))))
            }
            text = lead + .composerText(.bold(rule.name), .plain(after))
        }
        switch rule.action {
        case .createFork?:
            text += .composerText(.plain(" Want to "), .link("create a fork", Self.createForkURL), .plain("?"))
        case .switchBranches?:
            text += .composerText(.plain(" Want to "), .link("switch branches", Self.switchBranchesURL), .plain("?"))
        case nil:
            break
        }
        return text
    }

    /// The words a rules warning starts with, linked to the rulesets.
    static let rulesPhrase = "Repository rules"

    /// The link that offers a fork.
    public static let createForkURL = URL(string: "espalier-composer:create-fork")!
    /// The link that opens the branch popover.
    public static let switchBranchesURL = URL(string: "espalier-composer:switch-branches")!
}

extension CommitWarning {
    /// The warning for a repository's state, with the branch's rulesets for
    /// a rules warning.
    @MainActor
    public static func make(_ repository: RepositoryModel) -> CommitWarning? {
        guard let rule = repository.gitHub.commitWarning else {
            return nil
        }
        let rulesURL = rule.rulesBranch.flatMap { branch in
            repository.record.gitHubRepository.flatMap { GitHubWebURLs.rulesets(forBranch: branch, in: $0) }
        }
        return CommitWarning(rule, rulesURL: rulesURL)
    }
}

extension CommitRuleWarning {
    /// The branch or repository the warning names.
    nonisolated var name: String {
        switch self {
        case .noWriteAccess(let repositoryName): repositoryName
        case .branchProtected(let branch): branch
        case .publishRestricted(let branch, _), .signedCommitsRequired(let branch, _), .pushRestricted(let branch, _): branch
        }
    }

    /// The same warning naming `name`.
    nonisolated func naming(_ name: String) -> CommitRuleWarning {
        switch self {
        case .noWriteAccess: .noWriteAccess(repositoryName: name)
        case .branchProtected: .branchProtected(branch: name)
        case .publishRestricted(_, let canBypass): .publishRestricted(branch: name, canBypass: canBypass)
        case .signedCommitsRequired(_, let canBypass): .signedCommitsRequired(branch: name, canBypass: canBypass)
        case .pushRestricted(_, let canBypass): .pushRestricted(branch: name, canBypass: canBypass)
        }
    }

    /// The message's text before and after the name, found by wording the
    /// warning around a marker (a name can also appear in the sentence's own
    /// words). Nil if the message isn't worded that way.
    nonisolated var textAroundName: (before: String, after: String)? {
        let marker = "\u{FFFC}"
        let template = naming(marker).message
        guard let range = template.range(of: marker) else {
            return nil
        }
        let before = String(template[..<range.lowerBound])
        let after = String(template[range.upperBound...])
        guard before + name + after == message else {
            return nil
        }
        return (before, after)
    }

    /// The branch whose rulesets a rules warning links to.
    nonisolated var rulesBranch: String? {
        switch self {
        case .noWriteAccess, .branchProtected: nil
        case .publishRestricted(let branch, _), .signedCommitsRequired(let branch, _), .pushRestricted(let branch, _): branch
        }
    }
}

extension Tip {
    /// The branch a commit goes on: the current branch, or an unborn
    /// branch's name; nil on a detached HEAD.
    nonisolated var composerBranchName: String? {
        switch self {
        case .valid(let branch): branch.name
        case .unborn(let ref): ref
        case .detached, .unknown: nil
        }
    }
}

/// The warning above the commit button: a symbol and the text with its
/// links.
public struct CommitWarningView: View {
    private let warning: CommitWarning
    private let onLink: (URL) -> Void

    /// - Parameters:
    ///   - onLink: Runs a link: create a fork, switch branches, or open the
    ///     rulesets page.
    public init(_ warning: CommitWarning, onLink: @escaping (URL) -> Void = { _ in }) {
        self.warning = warning
        self.onLink = onLink
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Image(systemName: warning.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(Color(espalier: warning.isError ? Palette.error : Palette.warning))
                .accessibilityLabel(warning.isError ? "Error" : "Warning")
            Text(warning.message)
                .font(Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    onLink(url)
                    return .handled
                })
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Commit message rules

/// How the commit message fares against the branch's message rules.
nonisolated public struct MessageRuleFailures: Sendable, Equatable {
    /// A rule the message fails, with its ruleset's page.
    public struct Rule: Sendable, Equatable {
        /// What the rule asks: "must start with "JIRA-"".
        public var description: String
        public var rulesetURL: URL?

        public init(_ description: String, rulesetURL: URL? = nil) {
            self.description = description
            self.rulesetURL = rulesetURL
        }
    }

    /// The rules the message fails that can't be bypassed.
    public var failed: [Rule]
    /// The rules it fails that the user may bypass.
    public var bypassed: [Rule]
    /// The branch's rulesets ("View all rulesets for this branch").
    public var rulesetsURL: URL?

    public init(failed: [Rule], bypassed: [Rule] = [], rulesetsURL: URL? = nil) {
        self.failed = failed
        self.bypassed = bypassed
        self.rulesetsURL = rulesetsURL
    }

    /// Whether every failure can be bypassed.
    public var canBypass: Bool {
        failed.isEmpty
    }

    /// What the hint's popover says (the failures' own sentence, which
    /// counts them; their rulesets don't matter to it).
    public var summary: String {
        let failures = RepoRulesMetadataFailures(
            failed: failed.map { RepoRulesMetadataFailure(description: $0.description, rulesetId: 0) },
            bypassed: bypassed.map { RepoRulesMetadataFailure(description: $0.description, rulesetId: 0) }
        )
        return failures.summary(leadingText: "This commit message") ?? ""
    }
}

extension MessageRuleFailures {
    /// The failures as the hint shows them, each linked to its ruleset in
    /// `gitHubRepository`, or nil when every rule passes.
    ///
    /// - Parameter branch: The branch whose rulesets the popover links to.
    public init?(_ failures: RepoRulesMetadataFailures, gitHubRepository: GitHubRepository?, branch: String?) {
        guard failures.status != .pass else {
            return nil
        }
        func rules(_ failures: [RepoRulesMetadataFailure]) -> [Rule] {
            failures.map { failure in
                Rule(failure.description, rulesetURL: gitHubRepository.flatMap { GitHubWebURLs.ruleset(id: failure.rulesetId, in: $0) })
            }
        }
        self.init(
            failed: rules(failures.failed),
            bypassed: rules(failures.bypassed),
            rulesetsURL: branch.flatMap { branch in gitHubRepository.flatMap { GitHubWebURLs.rulesets(forBranch: branch, in: $0) } }
        )
    }
}

/// What the commit message's rule check reads: the draft, the single-file
/// placeholder, amending, and the branch's message rules (and where their
/// links go). The composer checks again (`commitMessageRuleFailures()`)
/// when it changes.
struct MessageRuleCheck: Equatable {
    var draft: CommitDraft
    var placeholder: String?
    var isAmending: Bool
    var isEnabled: Bool
    /// The message rules, as text (the rules themselves hold matchers).
    var rules: [String]
    var branch: String?
    var rulesetsURL: URL?

    @MainActor
    static func of(_ repository: RepositoryModel) -> MessageRuleCheck {
        let gitHub = repository.gitHub
        let rules = gitHub.repoRules?.commitMessagePatterns.getRules().map { rule in
            "\(rule.rulesetId) \(rule.enforced) \(rule.humanDescription)"
        }
        let branch = repository.gitState.tip.composerBranchName
        return MessageRuleCheck(
            draft: repository.commit.draft,
            placeholder: repository.commit.summaryPlaceholder,
            isAmending: repository.commit.amending != nil,
            isEnabled: gitHub.repoRulesEnabled,
            rules: rules ?? [],
            branch: branch,
            rulesetsURL: repository.record.gitHubRepository.flatMap { gitHubRepository in
                branch.flatMap { GitHubWebURLs.rulesets(forBranch: $0, in: gitHubRepository) }
            }
        )
    }
}

/// The summary's rule hint: an error or warning symbol that shows which
/// rules the message fails.
struct MessageRulesHint: View {
    let failures: MessageRuleFailures
    /// Opens a ruleset's page.
    var onLink: (URL) -> Void = { _ in }
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Image(systemName: failures.canBypass ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(Color(espalier: failures.canBypass ? Palette.warning : Palette.error))
        }
        .buttonStyle(.borderless)
        .help(failures.canBypass ? "The commit message fails repository rules you can bypass" : "The commit message fails repository rules")
        .accessibilityLabel(failures.canBypass
            ? "Warning: the commit message fails repository rules, but you can bypass them. View details."
            : "Error: the commit message fails repository rules. View details.")
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            MessageRuleFailuresView(failures: failures, onLink: onLink)
        }
    }
}

/// Which rules the commit message fails: the sentence, a link to the
/// branch's rulesets, and the failed and bypassed rules, each linked to its
/// ruleset.
struct MessageRuleFailuresView: View {
    let failures: MessageRuleFailures
    var onLink: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Text("Commit Message Rule Failures")
                .font(Typography.heading)
            Text(failures.summary)
                .font(Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = failures.rulesetsURL {
                Text(.composerText(.link("View all rulesets for this branch", url)))
                    .font(Typography.secondary)
            }
            ruleList("Failed Rules", failures.failed)
            ruleList("Bypassed Rules", failures.bypassed)
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Composer.popoverWidth, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            onLink(url)
            return .handled
        })
    }

    @ViewBuilder
    private func ruleList(_ title: String, _ rules: [MessageRuleFailures.Rule]) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                Text(title)
                    .font(Typography.subheadline.weight(.semibold))
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    Label {
                        Text(.composerText(.link(rule.description, rule.rulesetURL)))
                    } icon: {
                        EmptyView()
                    }
                    .labelStyle(RuleBulletLabelStyle())
                    .font(Typography.secondary)
                }
            }
        }
    }
}

/// A bulleted line.
struct RuleBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.grid) {
            Text("•")
                .foregroundStyle(.secondary)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Composing text

/// A run of text for `AttributedString.composerText(_:)`.
nonisolated enum ComposerTextRun {
    case plain(String)
    case bold(String)
    /// A link, or plain text when there's no URL.
    case link(String, URL?)
}

extension AttributedString {
    /// Text built from runs, so names (branches, repositories) are never
    /// read as Markdown.
    nonisolated static func composerText(_ runs: ComposerTextRun...) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .plain(let text):
                result.append(AttributedString(text))
            case .bold(let text):
                var bold = AttributedString(text)
                bold.inlinePresentationIntent = .stronglyEmphasized
                result.append(bold)
            case .link(let text, let url):
                var link = AttributedString(text)
                link.link = url
                result.append(link)
            }
        }
        return result
    }
}
