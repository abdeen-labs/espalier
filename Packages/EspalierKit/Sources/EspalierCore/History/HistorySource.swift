// The history logs the commits the scope asks for, starting from the
// commits its refs pointed at when the list was loaded, so pages stay
// consistent while refs move; it reloads when those commits, HEAD, or the
// trunk change.

import EspalierSupport
import GitKit

/// A branch or tag that points at a commit (for ref capsules).
public struct HistoryRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case localBranch
        case remoteBranch
        case tag
    }

    public let kind: Kind
    /// The ref's full name (`refs/heads/main`).
    public let fullName: String
    /// The name to show (`main`, `origin/main`, `v1.0`).
    public let name: String
    /// A local branch's upstream (`refs/remotes/origin/main`), if it has one.
    public let upstream: String?

    public init(kind: Kind, fullName: String, name: String, upstream: String? = nil) {
        self.kind = kind
        self.fullName = fullName
        self.name = name
        self.upstream = upstream
    }
}

/// The repository's branches (and, for the All Branches scope, tags) with
/// the objects they point at (`git for-each-ref`).
struct RefListing: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let ref: HistoryRef
        /// The commit a branch points at, or a tag's object (git peels it).
        let objectID: String
    }

    private(set) var entries: [Entry] = []
    /// The branches by the commit they point at, in the listing's order
    /// (local branches, then remote branches, each by name). Built with the
    /// listing, off the main actor.
    private(set) var branchesByCommit: [String: [HistoryRef]] = [:]

    init(entries: [Entry] = []) {
        for entry in entries {
            append(entry)
        }
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entry.ref.kind != .tag {
            branchesByCommit[entry.objectID, default: []].append(entry.ref)
        }
    }

    /// The object `fullName` points at, if it's listed.
    func objectID(of fullName: String) -> String? {
        entries.first { $0.ref.fullName.utf8.elementsEqual(fullName.utf8) }?.objectID
    }
}

private enum RefField: Hashable, Sendable {
    case fullName, shortName, objectID, upstream, symRef
}

/// Lists the branches, and tags when `includingTags`. Symbolic refs (such
/// as `refs/remotes/origin/HEAD`) are left out; what they point at is
/// listed anyway.
@concurrent
func listRefs(_ repository: Repository, includingTags: Bool) async throws -> RefListing {
    let parser = createForEachRefParser([
        RefField.fullName: "%(refname)",
        .shortName: "%(refname:short)",
        .objectID: "%(objectname)",
        .upstream: "%(upstream)",
        .symRef: "%(symref)",
    ])
    let prefixes = ["refs/heads", "refs/remotes"] + (includingTags ? ["refs/tags"] : [])
    let result = try await git(["for-each-ref"] + parser.formatArgs + prefixes, repository.path, "listHistoryRefs")
    var listing = RefListing()
    for record in try parser.parse(result.stdout) where record[.symRef].isEmpty {
        let fullName = record[.fullName]
        let kind: HistoryRef.Kind
        if JSCompat.startsWith(fullName, "refs/heads/") {
            kind = .localBranch
        } else if JSCompat.startsWith(fullName, "refs/remotes/") {
            kind = .remoteBranch
        } else {
            kind = .tag
        }
        let upstream = record[.upstream]
        listing.append(RefListing.Entry(
            ref: HistoryRef(
                kind: kind,
                fullName: fullName,
                name: record[.shortName],
                upstream: kind == .localBranch && !upstream.isEmpty ? upstream : nil
            ),
            objectID: record[.objectID]
        ))
    }
    return listing
}

/// What a history list is loaded from: the scope, HEAD, the commits it
/// starts from, and the default branch's commit (the trunk's candidate).
/// Two lists from equal sources are the same list.
struct HistorySource: Sendable, Equatable {
    var scope: HistoryScope
    /// HEAD's commit; nil on an unborn branch.
    var head: String?
    /// The commits (or tag objects) the history starts from, each once,
    /// HEAD's first.
    var revisions: [String]
    /// The default branch's commit, if there's a default branch.
    var defaultBranchTip: String?

    /// The source for `scope`, given HEAD and the refs.
    ///
    /// - Parameters:
    ///   - defaultBranchRef: The default branch's full name; its commit comes
    ///     from `refs` (fresher) or else `defaultBranchSHA`.
    init(scope: HistoryScope, head: String?, refs: RefListing, defaultBranchRef: String?, defaultBranchSHA: String?) {
        self.scope = scope
        self.head = head
        var revisions: [String] = []
        var seen: Set<String> = []
        func add(_ objectID: String) {
            if seen.insert(objectID).inserted {
                revisions.append(objectID)
            }
        }
        if let head {
            add(head)
        }
        switch scope {
        case .currentBranch:
            break
        case .localBranches:
            // Ref names compare by code units, as git's do.
            var objectIDs: [ExactString: String] = [:]
            for entry in refs.entries {
                objectIDs[ExactString(entry.ref.fullName)] = entry.objectID
            }
            for entry in refs.entries where entry.ref.kind == .localBranch {
                add(entry.objectID)
                // An upstream that's gone isn't listed, and one that's a
                // local branch is added as itself.
                if let upstream = entry.ref.upstream, let objectID = objectIDs[ExactString(upstream)] {
                    add(objectID)
                }
            }
        case .allBranches:
            for entry in refs.entries {
                add(entry.objectID)
            }
        }
        self.revisions = revisions
        defaultBranchTip = defaultBranchRef.flatMap(refs.objectID(of:)) ?? defaultBranchSHA
    }
}

extension HistorySource {
    /// Whether a list loaded from this source already shows what `source`
    /// would: the same scope, HEAD, and default branch, and the same
    /// starting commits, except for added ones the list already has (a new
    /// branch at a listed commit), which reach nothing new. The list keeps
    /// its own source then, so its pages stay consistent. A removed starting
    /// commit may have been the only way to some commits, so it doesn't
    /// count as the same.
    func shows(sameCommitsAs source: HistorySource, loaded: [String: Int]) -> Bool {
        if self == source {
            return true
        }
        guard scope == source.scope, head == source.head, defaultBranchTip == source.defaultBranchTip else {
            return false
        }
        let current = Set(revisions)
        return current.isSubset(of: source.revisions)
            && source.revisions.allSatisfy { current.contains($0) || loaded[$0] != nil }
    }
}

/// The trunk's tip for a history from `source`: the default branch's commit
/// when the history starts from it or HEAD contains it, else its merge base
/// with HEAD; HEAD when there's no default branch or it shares no history
/// with HEAD (the trunk is then HEAD's line). Nil when there's no commit.
@concurrent
func resolveTrunkTip(_ repository: Repository, _ source: HistorySource) async -> String? {
    guard let head = source.head else {
        // An unborn branch: the default branch is drawn as the trunk if the
        // history shows it.
        return source.defaultBranchTip.flatMap { source.revisions.contains($0) ? $0 : nil }
    }
    guard let tip = source.defaultBranchTip else {
        return head
    }
    if source.revisions.contains(tip) {
        return tip
    }
    let mergeBase = try? await getMergeBase(repository, head, tip)
    return mergeBase.flatMap { $0.isEmpty ? nil : $0 } ?? head
}
