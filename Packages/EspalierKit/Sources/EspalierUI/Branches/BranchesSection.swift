// The sidebar's Branches section, in the branch popover's groups: Default
// Branch, Recent Branches, Other Branches (the other local branches, in `/`
// folders), and Remote Branches (those no local branch tracks, one group
// per remote), each collapsible, the current branch in its group. Rows show
// each branch's pull request and how it compares with its upstream; the
// header has New Branch… and, after the branch pruner deleted branches this
// session, Restore Pruned Branch.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

// MARK: - Content

/// A folder of branches whose names share a `/` prefix, or a branch.
nonisolated public indirect enum BranchNode: Sendable, Equatable, Identifiable {
    case folder(BranchFolder)
    case branch(BranchRowContent)

    public var id: String {
        switch self {
        case .folder(let folder): "folder:\(folder.id)"
        case .branch(let row): row.ref
        }
    }
}

/// A folder: the branches whose names start with `path/`.
nonisolated public struct BranchFolder: Sendable, Equatable, Identifiable {
    /// The folder's scope (`other`, `remote/origin`) and path, which names
    /// its remembered expansion.
    public var id: String
    /// The folder's own name (the path's last component).
    public var name: String
    public var children: [BranchNode]

    public init(id: String, name: String, children: [BranchNode]) {
        self.id = id
        self.name = name
        self.children = children
    }
}

/// A remote's branches that no local branch tracks.
nonisolated public struct RemoteBranchGroup: Sendable, Equatable, Identifiable {
    public var name: String
    public var nodes: [BranchNode]

    public init(name: String, nodes: [BranchNode]) {
        self.name = name
        self.nodes = nodes
    }

    public var id: String {
        name
    }
}

/// What the Branches section shows.
nonisolated public struct BranchesSectionContent: Sendable, Equatable {
    /// HEAD's short SHA when it's detached: "Detached HEAD (a1b2c3d)".
    public var detachedSHA: String?
    /// The unborn branch HEAD is on, by name.
    public var unbornBranch: String?
    /// The default branch, the current one or not.
    public var defaultBranch: BranchRowContent?
    /// The recently checked out branches (at most five) but the default
    /// one, after a current branch the branch list doesn't have yet.
    public var recent: [BranchRowContent] = []
    /// Every other local branch, in `/` folders.
    public var other: [BranchNode] = []
    /// The remote branches no local branch tracks, by remote.
    public var remotes: [RemoteBranchGroup] = []
    /// Whether the sidebar filter narrows the rows (folders show open).
    public var isFiltering = false

    public init() {}

    /// Whether there's nothing to show.
    public var isEmpty: Bool {
        detachedSHA == nil && unbornBranch == nil && defaultBranch == nil
            && recent.isEmpty && other.isEmpty && remotes.isEmpty
    }

    /// Every branch row, in the order the section shows them (groups and
    /// folders open).
    public var allRows: [BranchRowContent] {
        var rows: [BranchRowContent] = []
        if let defaultBranch {
            rows.append(defaultBranch)
        }
        rows += recent
        func collect(_ nodes: [BranchNode]) {
            for node in nodes {
                switch node {
                case .folder(let folder): collect(folder.children)
                case .branch(let row): rows.append(row)
                }
            }
        }
        collect(other)
        for remote in remotes {
            collect(remote.nodes)
        }
        return rows
    }
}

nonisolated extension BranchesSectionContent {
    /// What the section is built from.
    nonisolated public struct Inputs: Sendable {
        public var branches: [Branch]
        public var tip: Tip
        public var defaultBranch: Branch?
        public var recentBranches: [Branch]
        /// The current branch's comparison with its upstream (the status's).
        public var currentAheadBehind: AheadBehind?
        /// The other local branches' (`branches.upstreamStates`), by ref.
        public var upstreamStates: [String: BranchUpstreamState]
        public var pullRequests: [PullRequest]
        /// The pull requests' checks, by number, where they're loaded.
        public var checks: [Int: ChecksState]
        public var remotes: [Remote]
        /// The sidebar filter's text.
        public var filter: String

        public init(
            branches: [Branch],
            tip: Tip,
            defaultBranch: Branch? = nil,
            recentBranches: [Branch] = [],
            currentAheadBehind: AheadBehind? = nil,
            upstreamStates: [String: BranchUpstreamState] = [:],
            pullRequests: [PullRequest] = [],
            checks: [Int: ChecksState] = [:],
            remotes: [Remote] = [],
            filter: String = ""
        ) {
            self.branches = branches
            self.tip = tip
            self.defaultBranch = defaultBranch
            self.recentBranches = recentBranches
            self.currentAheadBehind = currentAheadBehind
            self.upstreamStates = upstreamStates
            self.pullRequests = pullRequests
            self.checks = checks
            self.remotes = remotes
            self.filter = filter
        }
    }

    /// The section for a repository's branches.
    ///
    /// Built on the main actor whenever the section updates, so it's kept
    /// within a frame for thousands of branches: each branch's derived names
    /// are computed once, pull requests are found through an index, names
    /// are compared bridged once, and the folder tree is built in one pass.
    public static func make(_ inputs: Inputs) -> BranchesSectionContent {
        var content = BranchesSectionContent()
        let filter = inputs.filter.trimmingCharacters(in: .whitespaces)
        content.isFiltering = !filter.isEmpty
        let nameFilter = BranchNameFilter(filter)

        let currentBranch = inputs.tip.branch
        switch inputs.tip {
        case .detached(let sha) where nameFilter.matches("Detached HEAD"):
            content.detachedSHA = shortenSHA(sha)
        case .unborn(let ref):
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            if nameFilter.matches(name) {
                content.unbornBranch = name
            }
        default:
            break
        }

        let rows = BranchRowBuilder(inputs: inputs, current: currentBranch)
        let currentRef = currentBranch.map { ExactString($0.ref) }
        var shown = Set<ExactString>(minimumCapacity: inputs.branches.count + inputs.recentBranches.count + 2)
        /// The branch to show for `listed`: the current branch as the
        /// refresh has it (its tip may be newer than the branch list's).
        func fresh(_ listed: Branch, ref: ExactString) -> Branch {
            ref == currentRef ? currentBranch ?? listed : listed
        }
        func take(_ branch: Branch?) -> BranchRowContent? {
            guard let branch, !branch.isDesktopForkRemoteBranch else {
                return nil
            }
            let ref = ExactString(branch.ref)
            guard shown.insert(ref).inserted else {
                return nil
            }
            let shownBranch = fresh(branch, ref: ref)
            return nameFilter.matches(shownBranch.name) ? rows.row(shownBranch) : nil
        }

        content.defaultBranch = take(inputs.defaultBranch)
        content.recent = inputs.recentBranches.prefix(5).compactMap(take)

        var others: [PathRow] = []
        var remoteBranches: [String: [PathRow]] = [:]
        var remoteOrder: [String] = []
        for listed in inputs.branches {
            // Branches hidden or shown above are left out; a branch that
            // doesn't match the filter is still marked shown.
            let ref = ExactString(listed.ref)
            guard !listed.isDesktopForkRemoteBranch, shown.insert(ref).inserted else {
                continue
            }
            let branch = fresh(listed, ref: ref)
            guard nameFilter.matches(branch.name) else {
                continue
            }
            switch branch.type {
            case .local:
                others.append(PathRow(path: branch.name, row: rows.row(branch, title: branch.name)))
            case .remote:
                let names = RemoteBranchNames(branch)
                let remote = names.remote ?? "remote"
                if remoteBranches[remote] == nil {
                    remoteOrder.append(remote)
                }
                remoteBranches[remote, default: []].append(PathRow(path: names.path, row: rows.row(branch, title: names.path, remoteNames: names)))
            }
        }
        content.other = tree(others, scope: "other")
        content.remotes = NameOrder.sorted(remoteOrder, by: { $0 }).map { remote in
            RemoteBranchGroup(name: remote, nodes: tree(remoteBranches[remote] ?? [], scope: "remote/\(remote)"))
        }
        // A current branch the branch list doesn't have yet leads the
        // recent ones, which it's the latest of.
        if let currentRef, !shown.contains(currentRef), let current = take(currentBranch) {
            content.recent.insert(current, at: 0)
        }
        return content
    }

    /// Branches in folders by their names' `/` components: folders first,
    /// then branches, each by name (`localizedStandardCompare`); a branch's
    /// title is its name's last component. A component is the text before
    /// the first `/` when there's text after it; folder names that are
    /// canonically equivalent share a folder, named as first seen.
    static func tree(_ rows: [PathRow], scope: String) -> [BranchNode] {
        let root = BranchFolderBuilder()
        for item in rows {
            var folder = root
            var leaf = item.row
            var path = item.path
            // In ASCII every byte is a character, so a `/` byte is a `/`
            // character; elsewhere a `/` can begin or end a longer one. The
            // title's offset in bytes, for ASCII.
            let titleStart = path.withUTF8 { bytes -> Int? in
                guard bytes.allSatisfy({ $0 < 0x80 }) else {
                    return nil
                }
                var start = 0
                while true {
                    var slash = start
                    while slash < bytes.count, bytes[slash] != UInt8(ascii: "/") {
                        slash += 1
                    }
                    guard slash < bytes.count, slash != start, slash + 1 != bytes.count else {
                        return start
                    }
                    folder = folder.child(named: String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<slash]), as: UTF8.self))
                    start = slash + 1
                }
            }
            if let titleStart {
                leaf.title = titleStart == 0 ? path : String(decoding: path.utf8.dropFirst(titleStart), as: UTF8.self)
            } else {
                var rest = Substring(path)
                while let slash = rest.firstIndex(of: "/"), slash != rest.startIndex, rest.index(after: slash) != rest.endIndex {
                    folder = folder.child(named: String(rest[..<slash]))
                    rest = rest[rest.index(after: slash)...]
                }
                leaf.title = String(rest)
            }
            folder.leaves.append(leaf)
        }
        return root.nodes(scope: scope, prefix: "")
    }
}

/// A branch's row and the path its folders come from: the name, or a
/// remote branch's name without the remote.
nonisolated struct PathRow {
    var path: String
    var row: BranchRowContent
}

// MARK: - Building the content

/// A folder of the tree being built.
nonisolated private final class BranchFolderBuilder {
    /// The subfolders by name; a `String` key, so canonically equivalent
    /// names share one, keeping the spelling seen first.
    private var children: [String: BranchFolderBuilder] = [:]
    var leaves: [BranchRowContent] = []

    func child(named name: String) -> BranchFolderBuilder {
        if let child = children[name] {
            return child
        }
        let child = BranchFolderBuilder()
        children[name] = child
        return child
    }

    func nodes(scope: String, prefix: String) -> [BranchNode] {
        var nodes: [BranchNode] = []
        nodes.reserveCapacity(children.count + leaves.count)
        for (name, child) in NameOrder.sorted(Array(children), by: { $0.key }) {
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            nodes.append(.folder(BranchFolder(id: "\(scope):\(path)", name: name, children: child.nodes(scope: scope, prefix: path))))
        }
        for index in NameOrder.order(of: leaves.map(\.title)) {
            nodes.append(.branch(leaves[index]))
        }
        return nodes
    }
}

/// A remote branch's remote (nil when its ref isn't under
/// `refs/remotes/<remote>/`) and its name without the remote.
nonisolated private struct RemoteBranchNames {
    let remote: String?
    let path: String

    init(_ branch: Branch) {
        remote = (try? branch.remoteName) ?? nil
        path = branch.nameWithoutRemote
    }
}

/// The section's rows: how each branch compares with its upstream, and its
/// pull request.
nonisolated private struct BranchRowBuilder {
    let inputs: BranchesSectionContent.Inputs
    let current: ExactString?
    let pullRequests: PullRequestLookup?

    init(inputs: BranchesSectionContent.Inputs, current: Branch?) {
        self.inputs = inputs
        self.current = current.map { ExactString($0.ref) }
        pullRequests = inputs.pullRequests.isEmpty ? nil : PullRequestLookup(inputs.pullRequests, remotes: inputs.remotes)
    }

    func row(_ branch: Branch, title: String? = nil, remoteNames: RemoteBranchNames? = nil) -> BranchRowContent {
        let isCurrent = current == ExactString(branch.ref)
        return BranchRowContent(
            ref: branch.ref,
            name: branch.name,
            title: title,
            isCurrent: isCurrent,
            isRemote: branch.type == .remote,
            tracking: tracking(of: branch, isCurrent: isCurrent),
            pullRequest: pullRequest(for: branch, remoteNames: remoteNames),
            tipSHA: branch.tip.sha,
            isDefault: inputs.defaultBranch.map { ExactString($0.ref) == ExactString(branch.ref) } ?? false
        )
    }

    /// How `branch` compares with its upstream.
    private func tracking(of branch: Branch, isCurrent: Bool) -> BranchTracking {
        guard branch.type == .local else {
            return .none
        }
        if branch.upstream == nil {
            return .notPublished
        }
        if isCurrent, let aheadBehind = inputs.currentAheadBehind {
            return .aheadBehind(ahead: aheadBehind.ahead, behind: aheadBehind.behind)
        }
        switch inputs.upstreamStates[branch.ref] {
        case .tracking(let aheadBehind)?: return .aheadBehind(ahead: aheadBehind.ahead, behind: aheadBehind.behind)
        case .gone?: return .upstreamGone
        case nil: return .none
        }
    }

    /// The open pull request from `branch` (as `findAssociatedPullRequest`
    /// finds it: its head is the branch's upstream on the remote the
    /// upstream is on); for a remote branch, the pull request whose head is
    /// that branch.
    private func pullRequest(for branch: Branch, remoteNames: RemoteBranchNames?) -> BranchPullRequestBadge? {
        guard let pullRequests else {
            return nil
        }
        let pullRequest: PullRequest?
        switch branch.type {
        case .local:
            guard let remoteName = branch.upstreamRemoteName,
                  let remote = pullRequests.remote(named: remoteName),
                  let upstream = branch.upstreamWithoutRemote else {
                return nil
            }
            pullRequest = pullRequests.first(withHead: upstream, from: remote)
        case .remote:
            let names = remoteNames ?? RemoteBranchNames(branch)
            guard let remoteName = names.remote, let remote = pullRequests.remote(named: remoteName) else {
                return nil
            }
            pullRequest = pullRequests.first(withHead: names.path, from: remote)
        }
        guard let pullRequest else {
            return nil
        }
        return BranchPullRequestBadge(
            number: pullRequest.pullRequestNumber,
            isDraft: pullRequest.draft,
            checks: inputs.checks[pullRequest.pullRequestNumber]
        )
    }
}

/// Open pull requests by their heads' branch names, to find a branch's as
/// `findAssociatedPullRequest` does (the first pull request, in list order,
/// whose head is the branch and whose head repository the remote points at)
/// without comparing every branch with every pull request.
nonisolated final class PullRequestLookup {
    private let byHead: [ExactString: [PullRequest]]
    private let remotes: [Remote]
    /// `repositoryMatchesRemote`'s answers, which depend only on the three
    /// URLs: it parses them, and most pull requests come from a few
    /// repositories.
    private var answers: [[ExactString?]: Bool] = [:]

    init(_ pullRequests: [PullRequest], remotes: [Remote]) {
        var byHead: [ExactString: [PullRequest]] = [:]
        for pullRequest in pullRequests {
            byHead[ExactString(pullRequest.head.ref), default: []].append(pullRequest)
        }
        self.byHead = byHead
        self.remotes = remotes
    }

    /// The first remote named `name`.
    func remote(named name: String) -> Remote? {
        remotes.first { JSCompat.strictEquals($0.name, name) }
    }

    /// The first pull request, in list order, whose head is the branch
    /// `head` in the repository `remote` points at.
    func first(withHead head: String, from remote: Remote) -> PullRequest? {
        byHead[ExactString(head)]?.first { matches($0.head.gitHubRepository, remote) }
    }

    private func matches(_ repository: GitHubRepository, _ remote: Remote) -> Bool {
        let key = [repository.htmlURL.map(ExactString.init), repository.cloneURL.map(ExactString.init), ExactString(remote.url)]
        if let known = answers[key] {
            return known
        }
        let answer = repositoryMatchesRemote(repository, remoteURL: remote.url)
        answers[key] = answer
        return answer
    }
}

/// The sidebar filter's test for a name: a case-insensitive search in the
/// current locale, `localizedCaseInsensitiveContains`. `NSString`'s method
/// of that name means the same (Foundation documents both as the
/// case-insensitive `range(of:options:range:locale:)` with the current
/// locale) and doesn't bridge the locale for each name, as the `String`
/// method does.
nonisolated struct BranchNameFilter {
    /// The filter's text, trimmed; empty matches every name.
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func matches(_ name: String) -> Bool {
        text.isEmpty || (name as NSString).localizedCaseInsensitiveContains(text)
    }
}

/// Sorting by name in Finder's order, `localizedStandardCompare`, with the
/// standard library's stable sort's result, comparing fewer and cheaper:
/// each name is bridged to `NSString` once (the `String` method bridges
/// both strings for every comparison, then calls `NSString`'s); a cheap
/// guess at the order needs one comparison per name to confirm; and failing
/// that, a merge sort compares fewer pairs than the insertion sort the
/// standard library uses for runs of up to 64.
nonisolated enum NameOrder {
    static func sorted<Element>(_ elements: [Element], by name: (Element) -> String) -> [Element] {
        guard elements.count > 1 else {
            return elements
        }
        return order(of: elements.map(name)).map { elements[$0] }
    }

    /// The indices of `names` in Finder's order, ties in their order. A
    /// cheap guess (`NaturalOrder`) is kept when each pair of neighbors is
    /// in order, a tie only in the names' order: the stable sort's result is
    /// the only order with both, so the guess's quality costs only time.
    static func order(of names: [String]) -> [Int] {
        guard names.count > 1 else {
            return Array(names.indices)
        }
        let bridged = names.map { $0 as NSString }
        func compare(_ left: Int, _ right: Int) -> ComparisonResult {
            bridged[left].localizedStandardCompare(bridged[right] as String)
        }
        if let guess = NaturalOrder.guess(names) {
            var holds = true
            for position in 1..<guess.count {
                let left = guess[position - 1]
                let right = guess[position]
                let result = compare(left, right)
                if left < right ? result == .orderedDescending : result != .orderedAscending {
                    holds = false
                    break
                }
            }
            if holds {
                return guess
            }
        }
        return stableOrder(count: names.count) { compare($0, $1) == .orderedAscending }
    }

    /// The indices `0..<count` sorted stably by `areInIncreasingOrder`: a
    /// bottom-up merge sort that copies two runs already in order without
    /// merging them. Any stable sort gives a strict weak ordering's one
    /// order.
    static func stableOrder(count: Int, by areInIncreasingOrder: (Int, Int) -> Bool) -> [Int] {
        var order = Array(0..<count)
        guard count > 1 else {
            return order
        }
        var merged = order
        var width = 1
        while width < count {
            var start = 0
            while start < count {
                let middle = min(start + width, count)
                let end = min(start + 2 * width, count)
                if middle == end || !areInIncreasingOrder(order[middle], order[middle - 1]) {
                    // One run, or two in order already.
                    for index in start..<end {
                        merged[index] = order[index]
                    }
                } else {
                    var left = start
                    var right = middle
                    var index = start
                    while left < middle, right < end {
                        // The right run's element goes first only when it's
                        // smaller: equal elements keep their order.
                        if areInIncreasingOrder(order[right], order[left]) {
                            merged[index] = order[right]
                            right += 1
                        } else {
                            merged[index] = order[left]
                            left += 1
                        }
                        index += 1
                    }
                    while left < middle {
                        merged[index] = order[left]
                        left += 1
                        index += 1
                    }
                    while right < end {
                        merged[index] = order[right]
                        right += 1
                        index += 1
                    }
                }
                start = end
            }
            swap(&order, &merged)
            width *= 2
        }
        return order
    }
}

/// A guess at Finder's order for ASCII names that's cheap to sort by:
/// letters without case, runs of digits by their value, and other
/// characters as Finder orders them one by one. `NameOrder` checks it.
nonisolated enum NaturalOrder {
    /// Each ASCII character's place among single characters in Finder's
    /// order: a letter's is its lowercase's, and every digit has the place
    /// of `0`, which starts a run of digits. Computed once, in the locale of
    /// the time; a guess, so a stale one only costs time.
    static let ranks: [UInt8] = {
        func isUppercase(_ byte: UInt8) -> Bool {
            byte >= 0x41 && byte <= 0x5A
        }
        func isDigitAfterZero(_ byte: UInt8) -> Bool {
            byte >= 0x31 && byte <= 0x39
        }
        let all: [UInt8] = (0..<0x80).map { UInt8($0) }
        let ranked = all.filter { !isUppercase($0) && !isDigitAfterZero($0) }.sorted { left, right in
            String(UnicodeScalar(left)).localizedStandardCompare(String(UnicodeScalar(right))) == .orderedAscending
        }
        var ranks = [UInt8](repeating: 0, count: 0x80)
        for (rank, byte) in ranked.enumerated() {
            ranks[Int(byte)] = UInt8(rank + 1)
        }
        for byte in 0x41...0x5A {
            ranks[byte] = ranks[byte | 0x20]
        }
        for byte in 0x31...0x39 {
            ranks[byte] = ranks[0x30]
        }
        return ranks
    }()

    /// The names' indices sorted by their keys, ties in their order; nil
    /// when a name isn't ASCII.
    static func guess(_ names: [String]) -> [Int]? {
        var keys: [UInt8] = []
        var bounds: [Range<Int>] = []
        bounds.reserveCapacity(names.count)
        for name in names {
            let start = keys.count
            var name = name
            let isASCII = name.withUTF8 { bytes -> Bool in
                var index = 0
                while index < bytes.count {
                    let byte = bytes[index]
                    guard byte < 0x80 else {
                        return false
                    }
                    if byte >= 0x30, byte <= 0x39 {
                        // A run of digits: its length without leading
                        // zeros, then its digits, so runs compare by value.
                        var end = index
                        while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 {
                            end += 1
                        }
                        var first = index
                        while first < end - 1, bytes[first] == 0x30 {
                            first += 1
                        }
                        keys.append(ranks[0x30])
                        keys.append(UInt8(min(end - first, 0xFF)))
                        keys.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[first..<end]))
                        index = end
                    } else {
                        keys.append(ranks[Int(byte)])
                        index += 1
                    }
                }
                return true
            }
            guard isASCII else {
                return nil
            }
            bounds.append(start..<keys.count)
        }
        return keys.withUnsafeBufferPointer { keys in
            NameOrder.stableOrder(count: names.count) { left, right in
                let leftKey = bounds[left]
                let rightKey = bounds[right]
                let common = min(leftKey.count, rightKey.count)
                if common > 0, let base = keys.baseAddress {
                    let order = memcmp(base + leftKey.lowerBound, base + rightKey.lowerBound, common)
                    if order != 0 {
                        return order < 0
                    }
                }
                return leftKey.count < rightKey.count
            }
        }
    }
}

nonisolated extension BranchesSectionContent {
    /// The loaded checks of the repository's open pull requests
    /// (`checks(for:)`), by number.
    @MainActor
    static func checksByPullRequest(_ repository: RepositoryModel) -> [Int: ChecksState] {
        var checks: [Int: ChecksState] = [:]
        for pullRequest in repository.gitHub.openPullRequests {
            if let check = repository.gitHub.checks(for: pullRequest) {
                checks[pullRequest.pullRequestNumber] = BranchPullRequestBadge.checksState(of: check)
            }
        }
        return checks
    }

    /// The section for a repository, as the window shows it.
    @MainActor
    static func make(_ repository: RepositoryModel, upstreamStates: [String: BranchUpstreamState], filter: String) -> BranchesSectionContent {
        let state = repository.gitState
        return UISignposts.measure(.branchesApply) {
            make(Inputs(
                branches: state.branches.all,
                tip: state.tip,
                defaultBranch: state.branches.defaultBranch,
                recentBranches: state.branches.recent,
                currentAheadBehind: state.aheadBehind,
                upstreamStates: upstreamStates,
                pullRequests: repository.gitHub.openPullRequests,
                checks: checksByPullRequest(repository),
                remotes: state.remotes.all,
                filter: filter
            ))
        }
    }
}

// MARK: - The section

/// Branches, with New Branch… in the header.
public struct BranchesSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let content = BranchesSectionContent.make(
            repository,
            upstreamStates: repository.branches.upstreamStates,
            filter: context.state.sidebarFilter
        )
        let showsNewBranchDropRow = CommitDropDecision.showsNewBranchRow(in: context, repository: repository)
        // It stays while the repository's first status loads, so it doesn't
        // come in after the rest of the sidebar and move what's below it.
        if !content.isEmpty || showsNewBranchDropRow || !context.state.sidebarFilter.isEmpty || repository.gitState.tip.isValidBranch
            || !repository.gitState.loaded.contains(.status) {
            SidebarSection(id: "branches") {
                BranchesSectionRows(content: content, repository: repository, showsNewBranchDropRow: showsNewBranchDropRow)
            } header: {
                BranchesSectionHeader(prunedBranches: repository.sync.prunedBranches)
            }
        }
    }
}

/// The section's rows, value-driven: with a repository, the branch rows
/// (and the transient New Branch… row) take dropped commits.
struct BranchesSectionRows: View {
    let content: BranchesSectionContent
    var repository: RepositoryModel?
    var showsNewBranchDropRow = false

    var body: some View {
        if showsNewBranchDropRow {
            NewBranchDropRow(repository: repository)
        }
        if let sha = content.detachedSHA {
            SidebarRowLabel("Detached HEAD (\(sha))", systemImage: "smallcircle.filled.circle")
                .tooltip("Currently on a detached HEAD")
                .sidebarRow(nil, id: "detached")
        }
        if let unborn = content.unbornBranch {
            BranchRow(BranchRowContent(ref: "refs/heads/\(unborn)", name: unborn, isCurrent: true))
                .tooltip("Current branch is \(unborn)")
                .sidebarRow(nil, id: "unborn")
        }
        if let defaultBranch = content.defaultBranch {
            BranchGroupDisclosure(
                id: "branches.default",
                title: "Default Branch",
                isExpandedByDefault: true,
                isFiltering: content.isFiltering
            ) {
                BranchSidebarRow(content: defaultBranch, repository: repository)
            }
        }
        if !content.recent.isEmpty {
            BranchGroupDisclosure(
                id: "branches.recent",
                title: "Recent Branches",
                isExpandedByDefault: true,
                isFiltering: content.isFiltering
            ) {
                ForEach(content.recent) { row in
                    BranchSidebarRow(content: row, repository: repository)
                }
            }
        }
        if !content.other.isEmpty {
            BranchGroupDisclosure(
                id: "branches.other",
                title: "Other Branches",
                isExpandedByDefault: true,
                isFiltering: content.isFiltering
            ) {
                BranchNodeList(nodes: content.other, repository: repository, isFiltering: content.isFiltering)
            }
        }
        if !content.remotes.isEmpty {
            BranchGroupDisclosure(
                id: "branches.remote",
                title: "Remote Branches",
                isFiltering: content.isFiltering
            ) {
                ForEach(content.remotes) { remote in
                    BranchGroupDisclosure(
                        id: "branches.remote.\(remote.name)",
                        title: remote.name,
                        systemImage: "cloud",
                        isFiltering: content.isFiltering
                    ) {
                        BranchNodeList(nodes: remote.nodes, repository: repository, isFiltering: content.isFiltering)
                    }
                }
            }
        }
    }
}

/// A branch row in the sidebar: selectable, and, with a repository, a
/// target for dropped commits that loads how its branch compares with its
/// upstream while it's on screen.
struct BranchSidebarRow: View {
    let content: BranchRowContent
    let repository: RepositoryModel?
    @State private var isDropTarget = false

    var body: some View {
        let place = SidebarPlace.branch(ref: content.ref)
        let row = BranchRow(content, dotColor: repository.map { Self.dotColor(content, in: $0) })
            .sidebarRow(place, isDropTarget: isDropTarget)
            .tag(place)
        if let repository {
            row.commitDropTarget(.branch(name: content.name, isCurrent: content.isCurrent), repository: repository, isTargeted: $isDropTarget)
                .modifier(UpstreamStateWatcher(ref: content.watchesUpstreamState ? content.ref : nil, repository: repository))
        } else {
            row
        }
    }
}

extension BranchSidebarRow {
    /// The branch's color (`BranchColors`): the same as its tag's and its
    /// line's in History, loaded or not.
    static func dotColor(_ content: BranchRowContent, in repository: RepositoryModel) -> NSColor {
        let colors = BranchColors.of(repository)
        if content.isRemote {
            return colors.color(forRemoteBranch: content.name)
        }
        return colors.color(forBranch: content.name) ?? content.fallbackColor
    }
}

/// Keeps a local branch's upstream state loaded while its row is on screen;
/// rows that scroll away stop their loads.
private struct UpstreamStateWatcher: ViewModifier {
    /// The branch, or nil for a row without an upstream to compare.
    let ref: String?
    let repository: RepositoryModel

    func body(content: Content) -> some View {
        content.task(id: ref) {
            if let ref {
                await repository.branches.watchUpstreamState(of: ref)
            }
        }
    }
}

nonisolated extension BranchRowContent {
    /// Whether the row is a local branch with an upstream to compare.
    var watchesUpstreamState: Bool {
        !isRemote && tracking != .notPublished
    }
}

/// Folders and branches, folders as disclosure groups.
struct BranchNodeList: View {
    let nodes: [BranchNode]
    let repository: RepositoryModel?
    let isFiltering: Bool

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .branch(let row):
                BranchSidebarRow(content: row, repository: repository)
            case .folder(let folder):
                BranchGroupDisclosure(
                    id: "branches.folder.\(folder.id)",
                    title: folder.name,
                    systemImage: "folder",
                    isFiltering: isFiltering
                ) {
                    // Folders nest: the recursion goes through `AnyView`.
                    AnyView(BranchNodeList(nodes: folder.children, repository: repository, isFiltering: isFiltering))
                }
            }
        }
    }
}

/// A group of rows whose expansion is remembered; open while the sidebar
/// filter shows matches. A disclosure group of the sidebar's list, so its
/// rows are the list's rows a level in, and the list's chevron before its
/// label opens and closes it, as does a click anywhere on its label. The
/// section's own groups (Default Branch, Recent Branches, ...) are labeled
/// by name alone, in secondary text; a remote and a folder have their
/// symbol.
///
/// As in `SidebarSection`, the rows follow the expansion the group sets, a
/// state change (made inside its animation when the label is clicked), so
/// the list animates them in and out; the remembered expansion follows it
/// once that change has drawn, and a change made elsewhere (another window)
/// reaches the remembered one first.
struct BranchGroupDisclosure<Content: View>: View {
    let title: String
    let systemImage: String?
    let isFiltering: Bool
    let content: Content
    @AppStorage private var rememberedExpansion: Bool
    /// The expansion the group set, or nil before it sets one.
    @State private var chosenExpansion: Bool?
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - id: Names the remembered expansion (`sidebar.expanded.<id>`).
    ///   - systemImage: The row's symbol; nil for one of the section's
    ///     groups.
    ///   - isExpandedByDefault: The expansion before the user changes it.
    init(id: String, title: String, systemImage: String? = nil, isExpandedByDefault: Bool = false, isFiltering: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.isFiltering = isFiltering
        self.content = content()
        _rememberedExpansion = AppStorage(wrappedValue: isExpandedByDefault, "sidebar.expanded.\(id)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isOpen }, set: { setExpanded($0) })) {
            content
        } label: {
            // The group's own row; modifiers on the group would reach its
            // rows too.
            labelContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withMotion(motion, isOpen ? Motion.leave : Motion.arrive) {
                        setExpanded(!isOpen)
                    }
                }
                .sidebarRow(nil, id: "group:\(title)")
                .onChange(of: chosenExpansion) { _, chosen in
                    if let chosen {
                        rememberedExpansion = chosen
                    }
                }
                .onChange(of: rememberedExpansion) { _, remembered in
                    chosenExpansion = remembered
                }
        }
    }

    /// Whether the group shows its rows.
    private var isOpen: Bool {
        BranchGroupExpansion.isOpen(chosen: chosenExpansion, remembered: rememberedExpansion, isFiltering: isFiltering)
    }

    /// Opens or closes the group; while the filter shows matches it stays
    /// open.
    private func setExpanded(_ expanded: Bool) {
        let current = chosenExpansion ?? rememberedExpansion
        if let next = BranchGroupExpansion.change(to: expanded, from: current, isFiltering: isFiltering) {
            chosenExpansion = next
        }
    }

    /// The symbol and the title, or the title alone, in secondary text.
    @ViewBuilder
    private var labelContent: some View {
        if let systemImage {
            SidebarRowLabel(title, systemImage: systemImage)
        } else {
            Text(title)
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text2)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// When a branch group shows its rows, and what opening or closing it
/// changes.
nonisolated enum BranchGroupExpansion {
    /// Whether the group shows its rows: as the group set it, else as
    /// remembered, and always while the filter shows matches.
    static func isOpen(chosen: Bool?, remembered: Bool, isFiltering: Bool) -> Bool {
        isFiltering || (chosen ?? remembered)
    }

    /// The expansion to set when the user opens (`expanded`) or closes the
    /// group: nil when nothing changes, as while the filter holds it open.
    static func change(to expanded: Bool, from current: Bool, isFiltering: Bool) -> Bool? {
        guard !isFiltering, expanded != current else {
            return nil
        }
        return expanded
    }
}

/// The section's header: its title, Restore Pruned Branch when there's a
/// branch to restore, and New Branch….
struct BranchesSectionHeader: View {
    /// The branches the branch pruner deleted this session.
    let prunedBranches: [PrunedBranch]
    @Environment(WindowContext.self) private var context
    @Environment(\.fixedNow) private var fixedNow

    var body: some View {
        SidebarSectionHeader("Branches") {
            let pruned = prunedBranches
            if !pruned.isEmpty {
                PullDownButton("More Branch Actions") { [context, fixedNow] in
                    RestorePrunedBranchMenu.content(pruned: pruned, now: fixedNow ?? Date(), context: context)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(SidebarHeaderButtonStyle())
                .fixedSize()
                .tooltip("More")
            }
            Button {
                context.actions.perform(.newBranch(startPoint: nil))
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(SidebarHeaderButtonStyle())
            .disabled(!context.actions.canPerform(.newBranch(startPoint: nil)))
            .tooltip(ActionKind.newBranch.title)
            .accessibilityLabel(ActionKind.newBranch.title)
        }
        .contextMenuCard { [prunedBranches, context, fixedNow] in
            if !prunedBranches.isEmpty {
                RestorePrunedBranchMenu.content(pruned: prunedBranches, now: fixedNow ?? Date(), context: context)
            }
        }
    }
}

/// "Restore Pruned Branch ▸ <name> (deleted today)".
enum RestorePrunedBranchMenu {
    @MenuBuilder
    static func content(pruned: [PrunedBranch], now: Date, context: WindowContext) -> MenuContent {
        Submenu(ActionKind.restorePrunedBranch.title) {
            for branch in pruned {
                MenuAction(title(of: branch, now: now)) {
                    context.actions.perform(.restorePrunedBranch(name: branch.name))
                }
            }
        }
    }

    /// "feature (deleted today)", or the day it was deleted, in the
    /// calendar's time zone and locale.
    static func title(of branch: PrunedBranch, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(branch.date, inSameDayAs: now) {
            return "\(branch.name) (deleted today)"
        }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let day = branch.date.formatted(style)
        return "\(branch.name) (deleted \(day))"
    }
}

// MARK: - Context menu

/// A branch row's context menu.
enum BranchContextMenu {
    @MenuBuilder
    static func content(ref: String, context: WindowContext) -> MenuContent {
        if let repository = context.repository,
           let branch = repository.gitState.branches.all.first(where: { $0.ref == ref })
               ?? repository.gitState.tip.branch.flatMap({ $0.ref == ref ? $0 : nil }) {
            let actions = context.actions
            let current = repository.gitState.tip.branch
            let isCurrent = current?.ref == branch.ref
            actions.menuAction(.checkoutBranch(name: branch.name))
            actions.menuAction(.newWorktree(branch: branch.name), title: "Check Out in New Worktree…")
            if let current, !isCurrent {
                MenuDivider()
                actions.menuAction(.mergeIntoCurrentBranch(branch: branch.name), title: "Merge into \(current.name)…")
                actions.menuAction(.rebaseCurrentBranch(onto: branch.name), title: "Rebase \(current.name) onto \(branch.name)…")
                actions.menuAction(.compareToBranch(name: branch.name), title: "Compare with \(current.name)")
            }
            MenuDivider()
            if branch.type == .local {
                actions.menuAction(.viewBranchOnGitHub(name: branch.name))
            }
            actions.menuAction(.copyBranchName(name: branch.name))
            MenuDivider()
            if branch.type == .local {
                actions.menuAction(.renameBranch(name: branch.name))
            }
            actions.menuAction(.deleteBranch(name: branch.name))
        }
    }
}
