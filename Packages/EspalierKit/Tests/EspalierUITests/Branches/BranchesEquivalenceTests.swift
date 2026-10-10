// The branch picker gives the same results as the plain scoring in
// BranchesReference.swift, and the section's shortcuts (Finder's order, the
// sidebar filter) answer as the standard library does. Inputs mix generated
// branches with the names that tell the shortcuts apart: canonically
// equivalent folders, combining marks
// and prepended characters next to a slash, empty components, case and
// digits for Finder's order, pull requests sharing a head, and fork remotes.

import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A repeatable source of pseudo-random numbers (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Names that differ only where the shortcuts could go wrong.
private let trickyNames = [
    "café/menu", "cafe\u{301}/drinks", "Café/desserts",
    "a/\u{301}b", "\u{0600}/x", "x/\u{0600}y", "/lead", "trail/", "a//b", "a/b/", "//", "/",
    "Zeta", "alpha", "Beta", "beta", "BETA", "v2", "v10", "v1.10", "v1.9", "v1.09", "topic-2", "topic-10", "Topic-3",
    "🚀/launch", "feature/🎉", "İstanbul", "ıslak", "STRASSE", "straße", "ﬁle", "Ǆemal", "ＦＵＬＬ/width",
    "feature/login", "feature/Login", "feature/login-form", "fix/crash", "fix_crash", "fix.crash", "hotfix",
    "日本/ブランチ", "e\u{301}clair", "éclair", "tab\there", "dash-", "-dash", "under_score",
]

private let origin = Remote(name: "origin", url: "https://github.com/octo-org/website.git")
private let upstream = Remote(name: "upstream", url: "git@github.com:upstream-org/website.git")

private func owner(_ login: String) -> Owner {
    Owner(login: login, endpoint: getDotComAPIEndpoint(), id: 1)
}

private let mainRepository = gitHubRepoFixture(owner: "octo-org", name: "website")
private let upstreamRepository = gitHubRepoFixture(owner: "upstream-org", name: "website")
private let forkRepository = gitHubRepoFixture(owner: "someone", name: "website")
/// The main repository named by its clone URL alone, or its page alone.
private let cloneOnlyRepository = GitHubRepository(
    name: "website", owner: owner("octo-org"), dbID: 7, cloneURL: "https://github.com/octo-org/website.git"
)
private let pageOnlyRepository = GitHubRepository(
    name: "website", owner: owner("OCTO-ORG"), dbID: 8, htmlURL: "https://github.com/OCTO-ORG/Website"
)

/// Branches, pull requests, and states for the section, from `seed`.
private func sectionInputs(seed: UInt64, localCount: Int, remoteCount: Int, filter: String = "") -> BranchesSectionContent.Inputs {
    var random = SeededGenerator(state: seed)
    func sha(_ index: Int) -> String {
        let hex = String(index, radix: 16)
        return String(repeating: "0", count: 40 - hex.count) + hex
    }
    var local: [Branch] = []
    var states: [String: BranchUpstreamState] = [:]
    let names = (0..<localCount).map { index in
        index < trickyNames.count ? trickyNames[index] : "team-\(index % 20)/area-\(index % 7)/topic-\(index)"
    }
    for (index, name) in names.enumerated() {
        let upstreamName: String?
        switch random.next() % 6 {
        case 0: upstreamName = "origin/\(name)"
        case 1: upstreamName = "upstream/\(name)"
        case 2: upstreamName = "origin/renamed/\(name)"
        case 3: upstreamName = "gone/\(name)"
        default: upstreamName = nil
        }
        let branch = Branch(name: name, upstream: upstreamName, tip: BranchTip(sha: sha(index)), type: .local, ref: "refs/heads/\(name)")
        local.append(branch)
        if upstreamName != nil {
            switch random.next() % 3 {
            case 0: states[branch.ref] = .tracking(AheadBehind(ahead: Int(random.next() % 4), behind: Int(random.next() % 4)))
            case 1: states[branch.ref] = .gone
            default: break
            }
        }
    }
    var remote: [Branch] = (0..<remoteCount).map { index in
        let name = switch index % 4 {
        case 0: "origin/remote-only/topic-\(index)"
        case 1: "upstream/release/\(index)"
        case 2: "origin/\(trickyNames[index % trickyNames.count])"
        default: "upstream/\(index)"
        }
        return Branch(name: name, upstream: nil, tip: BranchTip(sha: sha(100_000 + index)), type: .remote, ref: "refs/remotes/\(name)")
    }
    // Fork remotes with either prefix, a remote branch whose ref isn't under
    // refs/remotes, and a branch listed twice.
    remote += [
        Branch(name: "espalier-someone/main", upstream: nil, tip: BranchTip(sha: sha(1)), type: .remote, ref: "refs/remotes/espalier-someone/main"),
        Branch(name: "github-desktop-someone/x", upstream: nil, tip: BranchTip(sha: sha(2)), type: .remote, ref: "refs/remotes/github-desktop-someone/x"),
        Branch(name: "odd/one", upstream: nil, tip: BranchTip(sha: sha(3)), type: .remote, ref: "refs/odd/one"),
    ]
    if let first = local.first {
        local.append(first)
    }

    // Pull requests: heads that are upstreams (some from the fork first, so
    // list order decides), remote-only branches, and heads nothing has.
    var pullRequests: [PullRequest] = []
    let repositories = [mainRepository, forkRepository, upstreamRepository, cloneOnlyRepository, pageOnlyRepository]
    for (index, branch) in local.enumerated() where index.isMultiple(of: 3) {
        let head = branch.upstreamWithoutRemote ?? branch.name
        let repository = repositories[Int(random.next() % UInt64(repositories.count))]
        pullRequests.append(pullRequest(1_000 + index, head: head, in: repository, draft: random.next() % 4 == 0))
        if random.next() % 3 == 0 {
            pullRequests.append(pullRequest(5_000 + index, head: head, in: repositories[Int(random.next() % UInt64(repositories.count))]))
        }
    }
    for (index, branch) in remote.enumerated() where index.isMultiple(of: 5) {
        pullRequests.append(pullRequest(9_000 + index, head: branch.nameWithoutRemote, in: index.isMultiple(of: 2) ? mainRepository : upstreamRepository))
    }
    pullRequests.append(pullRequest(9_999, head: "nobody-has-this", in: mainRepository))
    pullRequests.shuffle(using: &random)
    let checks = Dictionary(pullRequests.enumerated().compactMap { index, pullRequest -> (Int, ChecksState)? in
        index.isMultiple(of: 2) ? (pullRequest.pullRequestNumber, [ChecksState.success, .failure, .pending, .neutral][index % 4]) : nil
    }, uniquingKeysWith: { first, _ in first })

    let current = local[min(5, local.count - 1)]
    return BranchesSectionContent.Inputs(
        branches: local + remote,
        tip: .valid(branch: current),
        defaultBranch: local[min(1, local.count - 1)],
        recentBranches: [current, local[min(1, local.count - 1)], local[min(7, local.count - 1)], remote[0], local[min(9, local.count - 1)], local[min(11, local.count - 1)], local[min(13, local.count - 1)]],
        currentAheadBehind: AheadBehind(ahead: 1, behind: 2),
        upstreamStates: states,
        pullRequests: pullRequests,
        checks: checks,
        remotes: [origin, upstream, Remote(name: "origin", url: "https://example.com/elsewhere.git")],
        filter: filter
    )
}

@Suite("Branches content equivalence") @MainActor
struct BranchesEquivalenceTests {
    @Test("the picker scores every name as before the speedups")
    func pickerScores() {
        var random = SeededGenerator(state: 42)
        let alphabet = Array("abcXYZ019-_./ \t~^:?*[\\@{}!#é\u{301}\r\n")
        func randomString(_ length: Int) -> String {
            String((0..<length).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] })
        }
        let asciiCharacters = (0..<0x80).map { String(UnicodeScalar(UInt8($0))) }
        var names = trickyNames + asciiCharacters + (0..<300).map { _ in randomString(Int(random.next() % 12)) }
        names += (0..<200).map { "team-\($0 % 20)/area-\($0 % 7)/topic-\($0)" }
        var filters = ["a", "A", "t", "topic-4", "TEAM-3/AREA-2", "tpc49", "nothing", "-", "/", ".", "_c", "é", "E", "\r", "\r\n", "ss", "SS", "i", "İ", "fi"]
        filters += asciiCharacters
        filters += (0..<120).map { _ in randomString(1 + Int(random.next() % 4)) }
        var mismatches: [String] = []
        for name in names {
            for filter in filters where !filter.isEmpty {
                let score = BranchFilter.score(name, filter)
                let reference = ReferenceBranchFilter.score(name, filter)
                if score != reference {
                    mismatches.append("\(name.debugDescription) \(filter.debugDescription): \(String(describing: score)) ≠ \(String(describing: reference))")
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).joined(separator: "; "))")
    }

    @Test("the picker's content is the same as before for generated branches")
    func pickerContent() {
        let inputs = sectionInputs(seed: 5, localCount: 500, remoteCount: 100)
        for filter in ["", "t", "topic-4", "team-3/area-2", "tpc49", "nothing-matches", "É", "/x"] {
            let content = BranchPickerContent.make(branches: inputs.branches, defaultBranch: inputs.defaultBranch, recentBranches: inputs.recentBranches, includesRemoteBranches: true, filter: filter)
            // The unfiltered groups, scored with `ReferenceBranchFilter`.
            var expected = BranchPickerContent.make(branches: inputs.branches, defaultBranch: inputs.defaultBranch, recentBranches: inputs.recentBranches, includesRemoteBranches: true, filter: "")
            let trimmed = filter.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                expected.groups = expected.groups.map { group in
                    let scored = group.branches.enumerated().compactMap { index, branch -> (score: Int, index: Int, branch: Branch)? in
                        ReferenceBranchFilter.score(branch.name, trimmed).map { ($0, index, branch) }
                    }
                    let ordered = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                    return BranchPickerContent.Group(title: group.title, branches: ordered.map(\.branch))
                }.filter { !$0.branches.isEmpty }
                expected.filter = trimmed
            }
            #expect(content == expected, "filter \"\(filter)\"")
        }
    }

    @Test("names sort in Finder's order, as the standard library sorts them")
    func nameOrder() {
        var random = SeededGenerator(state: 7)
        let corpus = trickyNames + (0..<300).map { "topic-\($0 % 37)-\($0)" } + ["a", "A", "a", "b", "B10", "b9", "", " "]
        for length in [0, 1, 2, 3, 5, 17, 64, 65, 200, corpus.count] {
            let names = Array(corpus.shuffled(using: &random).prefix(length))
            let expected = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            #expect(NameOrder.sorted(names, by: { $0 }) == expected, "\(length) names")
        }
        // ASCII names, which NameOrder first sorts by a guess: where the
        // guess holds (numbers), and where it can't know the order (case
        // alone, leading zeros, punctuation, characters git refuses).
        let asciiLists = [
            (0..<120).map { "topic-\($0 * 7 % 120)" },
            ["Topic", "topic", "TOPIC", "toPic", "topic", "Topic"],
            ["a01", "a1", "a001", "a10", "a010", "a2", "A1", "a1a", "a1-", "a1_"],
            ["a_b", "a-b", "a.b", "ab", "a b", "a~b", "a!b", "a@b", "a#b", "a+b", "a=b", "a,b", "a;b", "a'b", "a(b", "a`b", "a^b", "a|b"],
            ["~x", "!x", "x~", "x!", "_", "-", ".", "0", "9", "a", "A", "z", "Z", ""],
            (0..<0x80).map { String(UnicodeScalar(UInt8($0))) },
            ["v1.10", "v1.9", "v1.09", "v10", "v2", "v2.0.0", "v2.0", "release-2024-01", "release-2023-12", "release-2024-1"],
        ]
        for list in asciiLists {
            for _ in 0..<4 {
                let names = list.shuffled(using: &random)
                let expected = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                #expect(NameOrder.sorted(names, by: { $0 }) == expected, "\(names.prefix(6))")
            }
        }
        // Stable for equal elements: the merge keeps their order.
        let pairs = [(name: "b", index: 0), (name: "a", index: 1), (name: "b", index: 2), (name: "a", index: 3)]
        #expect(NameOrder.sorted(pairs, by: { $0.name }).map { $0.index } == [1, 3, 0, 2])
        #expect(NameOrder.stableOrder(count: 6) { $0 % 3 < $1 % 3 } == [0, 3, 1, 4, 2, 5])
    }

    @Test("the sidebar filter matches as localizedCaseInsensitiveContains")
    func nameFilter() {
        for filter in ["", "a", "É", "e\u{301}", "STRASSE", "ss", "i", "I", "İ", "ﬁ", "fi", "ＦＵＬＬ", "full", "🚀", "/", "topic-1"] {
            let nameFilter = BranchNameFilter(filter)
            for name in trickyNames + ["", "Detached HEAD", "topic-10"] {
                #expect(nameFilter.matches(name) == (filter.isEmpty || name.localizedCaseInsensitiveContains(filter)), "\(name.debugDescription) \(filter.debugDescription)")
            }
        }
    }
}
