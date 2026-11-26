// What a status says about a worktree, in the few values that tell
// activity: comparing a worktree's snapshot with its previous one says
// what happened in between (`WorktreeActivityModel.recordStatus`).

import CryptoKit
import Darwin
import EspalierSupport
import Foundation
import GitKit

/// What a status told about a worktree: where HEAD is, how far the branch
/// is behind its upstream, and a fingerprint of the changed files.
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

    public init(tip: String?, branch: String?, upstream: String? = nil, behind: Int? = nil, changedFiles: String = "") {
        self.tip = tip
        self.branch = branch
        self.upstream = upstream
        self.behind = behind
        self.changedFiles = changedFiles
    }

    /// The snapshot of `status`, the status of the worktree at
    /// `workingDirectory`. It reads each changed file's attributes
    /// (`lstat`), off the main actor.
    @concurrent
    public static func load(_ status: StatusResult, workingDirectory: String) async -> WorktreeStatusSnapshot {
        WorktreeStatusSnapshot(
            tip: status.currentTip.flatMap { $0.isEmpty ? nil : $0 },
            branch: status.currentBranch.flatMap { $0.isEmpty ? nil : $0 },
            upstream: status.currentUpstreamBranch.flatMap { $0.isEmpty ? nil : $0 },
            behind: status.branchAheadBehind?.behind,
            changedFiles: changedFilesFingerprint(status.workingDirectory.files, in: workingDirectory)
        )
    }

    public static func == (lhs: WorktreeStatusSnapshot, rhs: WorktreeStatusSnapshot) -> Bool {
        exactlyEqual(lhs.tip, rhs.tip) && exactlyEqual(lhs.branch, rhs.branch) && exactlyEqual(lhs.upstream, rhs.upstream)
            && lhs.behind == rhs.behind && exactlyEqual(lhs.changedFiles, rhs.changedFiles)
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
/// files.
///
/// It differs once a file becomes changed, stops being changed, changes
/// status, or is written again. Nothing is read but each file's attributes
/// (one `lstat` a file), so thousands of changed files cost milliseconds.
/// What a status doesn't list changes nothing: an ignored file, a tracked
/// file touched without a content change, git's index.
func changedFilesFingerprint(_ files: [WorkingDirectoryFileChange], in workingDirectory: String) -> String {
    guard !files.isEmpty else {
        return ""
    }
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
    return hasher.finalize().map { byte in
        let digits = String(byte, radix: 16)
        return byte < 16 ? "0" + digits : digits
    }.joined()
}
