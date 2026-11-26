// What a status says about a worktree, in the few values that tell
// activity: comparing a worktree's snapshot with its previous one says
// what happened in between (`WorktreeActivityModel.recordStatus`).

import CryptoKit
import Darwin
import EspalierSupport
import Foundation
import GitKit

/// What a status told about a worktree: where HEAD is, how far the branch
/// is behind its upstream, a fingerprint of the changed files, and when the
/// worktree last changed on disk.
///
/// Kept for every worktree, between launches too, and compared with the
/// next status's (`activity(since:)`). Its strings compare byte for byte,
/// as git's do.
public struct WorktreeStatusSnapshot: Sendable, Equatable, Codable {
    /// HEAD's commit; nil on a branch with no commit yet.
    public var tip: String?
    /// The branch HEAD is on; nil when it's detached.
    public var branch: String?
    /// The branch's upstream; nil without one.
    public var upstream: String?
    /// How many commits the branch is behind its upstream; nil without
    /// one.
    public var behind: Int?
    /// A fingerprint of the changed files (`changedFilesFingerprint`);
    /// empty with none.
    public var changedFiles: String
    /// When the worktree last changed, as the file system has it whether or
    /// not Espalier was running: the latest of its changed files'
    /// modification times (those on disk) and of its HEAD's last move (its
    /// `logs/HEAD`'s). Nil when neither is known.
    public var lastChanged: Date?
    /// A few of the changed files, those with conflicts first, then in the
    /// status's order: at most `changedFilesSampleLimit`. Saved, so they
    /// show at the next launch, and not compared: the fingerprint changes
    /// whenever they do.
    public var changedFilesSample: [ChangedFileSample]

    /// How many changed files a snapshot keeps the names of.
    public static let changedFilesSampleLimit = 3

    private enum CodingKeys: String, CodingKey {
        case tip, branch, upstream, behind, changedFiles, lastChanged, changedFilesSample
    }

    public init(
        tip: String?,
        branch: String?,
        upstream: String? = nil,
        behind: Int? = nil,
        changedFiles: String = "",
        lastChanged: Date? = nil,
        changedFilesSample: [ChangedFileSample] = []
    ) {
        self.tip = tip
        self.branch = branch
        self.upstream = upstream
        self.behind = behind
        self.changedFiles = changedFiles
        self.lastChanged = lastChanged
        self.changedFilesSample = changedFilesSample
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tip = try container.decodeIfPresent(String.self, forKey: .tip)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        changedFiles = try container.decode(String.self, forKey: .changedFiles)
        lastChanged = try container.decodeIfPresent(Date.self, forKey: .lastChanged)
        changedFilesSample = try container.decodeIfPresent([ChangedFileSample].self, forKey: .changedFilesSample) ?? []
    }

    /// The snapshot of `status`, the status of the worktree at
    /// `workingDirectory` whose git directory is `gitDirectory` (nil when
    /// it isn't known: its HEAD's moves aren't read). It reads each changed
    /// file's attributes and `logs/HEAD`'s (`lstat`), off the main actor;
    /// no git runs.
    @concurrent
    public static func load(_ status: StatusResult, workingDirectory: String, gitDirectory: String?) async -> WorktreeStatusSnapshot {
        let files = changedFilesFingerprint(status.workingDirectory.files, in: workingDirectory)
        let headMoved = gitDirectory.flatMap { modificationDate(POSIXPath.join($0, "logs/HEAD")) }
        return WorktreeStatusSnapshot(
            tip: status.currentTip.flatMap { $0.isEmpty ? nil : $0 },
            branch: status.currentBranch.flatMap { $0.isEmpty ? nil : $0 },
            upstream: status.currentUpstreamBranch.flatMap { $0.isEmpty ? nil : $0 },
            behind: status.branchAheadBehind?.behind,
            changedFiles: files.fingerprint,
            lastChanged: [files.latestModification, headMoved].compactMap(\.self).max(),
            changedFilesSample: sampleChangedFiles(status.workingDirectory.files)
        )
    }

    public static func == (lhs: WorktreeStatusSnapshot, rhs: WorktreeStatusSnapshot) -> Bool {
        exactlyEqual(lhs.tip, rhs.tip) && exactlyEqual(lhs.branch, rhs.branch) && exactlyEqual(lhs.upstream, rhs.upstream)
            && lhs.behind == rhs.behind && exactlyEqual(lhs.changedFiles, rhs.changedFiles) && lhs.lastChanged == rhs.lastChanged
    }

    /// What happened in the worktree between `previous`, an earlier
    /// snapshot of it, and this one.
    ///
    /// - `files`: the changed files' fingerprint differs.
    /// - `head`: the tip commit or the branch differs.
    /// - `server`: on the same branch with the same upstream, the branch is
    ///   further behind.
    public func activity(since previous: WorktreeStatusSnapshot) -> Set<WorktreeActivityKind> {
        var kinds: Set<WorktreeActivityKind> = []
        if !exactlyEqual(changedFiles, previous.changedFiles) {
            kinds.insert(.files)
        }
        let isSameBranch = exactlyEqual(branch, previous.branch)
        if !isSameBranch || !exactlyEqual(tip, previous.tip) {
            kinds.insert(.head)
        }
        if isSameBranch, exactlyEqual(upstream, previous.upstream), let behind, let behindBefore = previous.behind, behind > behindBefore {
            kinds.insert(.server)
        }
        return kinds
    }
}

/// One of a worktree's changed files, by name.
public struct ChangedFileSample: Sendable, Equatable, Codable {
    /// The path in the worktree.
    public var path: String
    public var kind: AppFileStatusKind

    public init(path: String, kind: AppFileStatusKind) {
        self.path = path
        self.kind = kind
    }
}

/// `WorktreeStatusSnapshot.changedFilesSample` for `files`.
private func sampleChangedFiles(_ files: [WorkingDirectoryFileChange]) -> [ChangedFileSample] {
    let limit = WorktreeStatusSnapshot.changedFilesSampleLimit
    let conflicted = files.lazy.filter { $0.status.kind == .conflicted }.prefix(limit)
    let others = files.lazy.filter { $0.status.kind != .conflicted }.prefix(limit - conflicted.count)
    return (Array(conflicted) + Array(others)).map { ChangedFileSample(path: $0.path, kind: $0.status.kind) }
}

/// Whether both are nil, or the same string byte for byte.
private func exactlyEqual(_ x: String?, _ y: String?) -> Bool {
    switch (x, y) {
    case (nil, nil): true
    case (let x?, let y?): JSCompat.strictEquals(x, y)
    default: false
    }
}

/// A fingerprint of a status's changed files, the same for the same files
/// in the same state: a SHA-256, in hexadecimal, over each file's path and
/// status and its mode, size, and modification time on disk; empty with no
/// files. With it, the latest modification time among the files on disk.
///
/// It differs once a file becomes changed, stops being changed, changes
/// status, or is written again. Nothing is read but each file's attributes
/// (one `lstat` a file), so thousands of changed files cost milliseconds.
/// What a status doesn't list changes nothing: an ignored file, a tracked
/// file touched without a content change, git's index.
func changedFilesFingerprint(
    _ files: [WorkingDirectoryFileChange],
    in workingDirectory: String
) -> (fingerprint: String, latestModification: Date?) {
    guard !files.isEmpty else {
        return ("", nil)
    }
    var latest: timespec?
    let directory = JSCompat.endsWith(workingDirectory, "/") ? workingDirectory : workingDirectory + "/"
    var hasher = SHA256()
    var buffer: [UInt8] = []
    let flushSize = 64 * 1024
    buffer.reserveCapacity(flushSize + 4096)

    func append(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    for file in files {
        // The ID is the status and the path (and a rename's old path); a
        // byte no path holds ends it.
        buffer.append(contentsOf: file.id.utf8)
        buffer.append(0)
        var attributes = stat()
        if lstat(directory + file.path, &attributes) == 0 {
            buffer.append(1)
            append(UInt32(attributes.st_mode))
            append(Int64(attributes.st_size))
            append(Int64(attributes.st_mtimespec.tv_sec))
            append(Int64(attributes.st_mtimespec.tv_nsec))
            let modified = attributes.st_mtimespec
            if latest.map({ ($0.tv_sec, $0.tv_nsec) < (modified.tv_sec, modified.tv_nsec) }) ?? true {
                latest = modified
            }
        } else {
            // Not on disk: deleted.
            buffer.append(0)
        }
        if buffer.count >= flushSize {
            hasher.update(data: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
    hasher.update(data: buffer)
    let fingerprint = hasher.finalize().map { byte in
        let digits = String(byte, radix: 16)
        return byte < 16 ? "0" + digits : digits
    }.joined()
    return (fingerprint, latest.map(date))
}

/// When the file at `path` was last modified (`lstat`); nil when it isn't
/// there.
private func modificationDate(_ path: String) -> Date? {
    var attributes = stat()
    guard lstat(path, &attributes) == 0 else {
        return nil
    }
    return date(attributes.st_mtimespec)
}

private func date(_ time: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
}
