// Ported from desktop/app/src/models/branch.ts

import EspalierSupport
import Foundation

// NOTE: The values here matter as they are used to sort
// local and remote branches, Local should come before Remote
public enum BranchType: Int, Hashable, Sendable {
    case local = 0
    case remote = 1
}

/// The number of commits a revision range is ahead/behind.
public struct AheadBehind: Hashable, Sendable {
    public let ahead: Int
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// The result of comparing two refs in a repository.
public struct CompareResult: Hashable, Sendable {
    public let ahead: Int
    public let behind: Int
    public let commits: [Commit]

    public init(ahead: Int, behind: Int, commits: [Commit]) {
        self.ahead = ahead
        self.behind = behind
        self.commits = commits
    }
}

/// Basic data about a branch, and the branch it's tracking.
public struct TrackingBranch: Hashable, Sendable {
    public let ref: String
    public let sha: String
    public let upstreamRef: String
    public let upstreamSha: String

    public init(ref: String, sha: String, upstreamRef: String, upstreamSha: String) {
        self.ref = ref
        self.sha = sha
        self.upstreamRef = upstreamRef
        self.upstreamSha = upstreamSha
    }
}

/// Basic data about the latest commit on the branch.
public struct BranchTip: Hashable, Sendable {
    public let sha: String

    public init(sha: String) {
        self.sha = sha
    }
}

/// Default rules for where to create a branch from
public enum StartPoint: String, Hashable, Sendable {
    case currentBranch = "CurrentBranch"
    case defaultBranch = "DefaultBranch"
    case head = "Head"
    /// Only valid for forks
    case upstreamDefaultBranch = "UpstreamDefaultBranch"
}

/// `/(.*?)\/.*/`
private let upstreamRemoteNamePattern = JSCompat.regex("(\(JSCompat.dot)*?)/\(JSCompat.dot)*")

/// `/^refs\/remotes\/(.*?)\/.*/`
private let remoteNamePattern = JSCompat.regex("^refs/remotes/(\(JSCompat.dot)*?)/\(JSCompat.dot)*")

/// A branch as loaded from Git.
public struct Branch: Hashable, Sendable {
    /// The short name of the branch. E.g., `main`.
    public let name: String
    /// The remote-prefixed upstream name. E.g., `origin/main`.
    public let upstream: String?
    /// Basic information (sha and author) of the latest commit on the branch.
    public let tip: BranchTip
    /// The type of branch, e.g., local or remote.
    public let type: BranchType
    /// The canonical ref of the branch
    public let ref: String

    /// A branch as loaded from Git.
    ///
    /// - Parameters:
    ///   - name: The short name of the branch. E.g., `main`.
    ///   - upstream: The remote-prefixed upstream name. E.g., `origin/main`.
    ///   - tip: Basic information (sha and author) of the latest commit on the branch.
    ///   - type: The type of branch, e.g., local or remote.
    ///   - ref: The canonical ref of the branch
    public init(name: String, upstream: String?, tip: BranchTip, type: BranchType, ref: String) {
        self.name = name
        self.upstream = upstream
        self.tip = tip
        self.type = type
        self.ref = ref
    }

    /// The name of the upstream's remote.
    public var upstreamRemoteName: String? {
        guard let upstream, !upstream.isEmpty else {
            return nil
        }

        switch FirstSlashSplit(upstream) {
        case .split(let before, _):
            return before
        case .noSlash:
            return nil
        case .lineTerminator:
            return Self.upstreamRemoteNameMatchingPattern(upstream)
        }
    }

    /// `upstreamRemoteName` of a non-empty upstream, by its regular
    /// expression.
    static func upstreamRemoteNameMatchingPattern(_ upstream: String) -> String? {
        guard let pieces = JSCompat.match(upstream, upstreamRemoteNamePattern), pieces.count >= 2 else {
            return nil
        }

        return pieces[1]
    }

    /// The name of remote for a remote branch. If local, will return nil.
    ///
    /// - Throws: `ModelError` if a remote branch's ref doesn't start with
    ///   `refs/remotes/<remote>/`.
    public var remoteName: String? {
        get throws {
            if type == .local {
                return nil
            }

            guard let name = Self.remoteName(ofRef: ref) else {
                // This shouldn't happen, the remote ref should always be prefixed
                // with refs/remotes
                throw ModelError("Remote branch ref has unexpected format: \(ref)")
            }
            return name
        }
    }

    /// The remote a remote branch's ref names, the text between
    /// `refs/remotes/` and the next `/`; nil where `remoteName` throws.
    static func remoteName(ofRef ref: String) -> String? {
        // The expression is anchored on this literal prefix.
        let prefix = "refs/remotes/"
        guard ref.utf8.starts(with: prefix.utf8) else {
            return nil
        }
        switch FirstSlashSplit(ref, from: prefix.utf8.count) {
        case .split(let before, _):
            return before
        case .noSlash:
            return nil
        case .lineTerminator:
            return remoteNameMatchingPattern(ref)
        }
    }

    /// `remoteName(ofRef:)` by `remoteName`'s regular expression.
    static func remoteNameMatchingPattern(_ ref: String) -> String? {
        guard let pieces = JSCompat.match(ref, remoteNamePattern), pieces.count == 2 else {
            return nil
        }
        return pieces[1]
    }

    /// The name of the branch's upstream without the remote prefix.
    public var upstreamWithoutRemote: String? {
        guard let upstream, !upstream.isEmpty else {
            return nil
        }

        return removeRemotePrefix(upstream)
    }

    /// The name of the branch without the remote prefix. If the branch is a local
    /// branch, this is the same as its `name`.
    public var nameWithoutRemote: String {
        if type == .local {
            return name
        } else {
            // An empty result falls back to the name too.
            if let withoutRemote = removeRemotePrefix(name), !withoutRemote.isEmpty {
                return withoutRemote
            }
            return name
        }
    }

    /// Gets a value indicating whether the branch is a remote branch belonging to
    /// one of the app's automatically created (and pruned) fork remotes: the
    /// remotes named in `forkRemoteNames`, the ones Espalier marked
    /// (`getForkRemoteNames`).
    ///
    /// We hide branches from our known fork remotes as these are considered
    /// plumbing and can add noise to everywhere in the user interface where we
    /// display branches as forks will likely contain duplicates of the same ref
    /// names
    public func isForkRemoteBranch(_ forkRemoteNames: Set<ExactString>) -> Bool {
        guard type == .remote, !forkRemoteNames.isEmpty else {
            return false
        }
        return forkRemoteNames.contains { JSCompat.startsWith(ref, "refs/remotes/\($0.value)/") }
    }
}
