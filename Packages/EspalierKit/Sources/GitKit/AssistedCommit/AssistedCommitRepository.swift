// Ported from desktop/app/src/lib/git/assisted-commit/git.ts
//
// - Attributes are read live, as an ordinary commit reads them, rather than
//   frozen into a private attribute tree: capture hashes each selected file
//   once, in a private index seeded from HEAD, and then checks the file
//   didn't change.
// - Git LFS keeps its objects in the repository's own storage
//   (`lfs.storage`), so a cleaned file's object outlives the private
//   metadata.

import Darwin
import EspalierSupport
import Foundation

/// The repository as a run found it, which every check compares with.
struct AssistedRepositoryIdentity: Sendable {
    let repository: Repository
    /// The working directory's real path.
    let root: String
    /// The git directory's real path (a linked worktree's own).
    let gitDirectory: String
    let indexPath: String
    let originalIndex: AssistedIndexState
    /// HEAD's bytes, which must not change while HEAD names a branch.
    let originalHeadBytes: Data
    let originalHead: AssistedCommitHead
    /// The null object ID in the repository's object format.
    let zeroID: String

    /// The ref a run updates: HEAD's branch, or HEAD itself when detached.
    var updatedRef: String {
        originalHead.ref ?? "HEAD"
    }
}

/// The index file's bytes, permissions, and times, or its absence.
struct AssistedIndexState: Sendable {
    let bytes: Data?
    let mode: mode_t
    let times: (access: AssistedTimestamp, modification: AssistedTimestamp)?

    /// The same bytes (and permissions, for a file that exists).
    func matches(_ other: AssistedIndexState) -> Bool {
        bytes == other.bytes && (bytes == nil || mode == other.mode)
    }
}

/// A tree entry: mode, object, and path.
struct AssistedTreeEntry: Sendable, Hashable {
    let path: String
    let mode: String
    let sha: String
}

/// A selected file as capture read it.
enum AssistedCapturedFileState: Sendable, Equatable {
    case missing
    case directory
    case file(AssistedFileIdentity, Data)
    case symlink(AssistedFileIdentity, Data)

    var bytes: Data? {
        switch self {
        case .file(_, let bytes), .symlink(_, let bytes): bytes
        case .missing, .directory: nil
        }
    }
}

/// Removes one trailing newline (`\n` or `\r\n`).
func assistedTrimLine(_ text: String) -> String {
    var scalars = text.unicodeScalars
    if scalars.last == "\n" {
        scalars.removeLast()
        if scalars.last == "\r" {
            scalars.removeLast()
        }
    }
    return String(scalars)
}

/// Whether `sha` is a full SHA-1 or SHA-256 object ID.
func assistedIsFullObjectID(_ sha: String) -> Bool {
    (sha.utf8.count == 40 || sha.utf8.count == 64)
        && sha.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
}

/// Throws unless `path` is a plain repository-relative path: not empty, no
/// NUL, not absolute, and no empty, `.`, `..`, or `.git` component.
func assistedValidatePath(_ path: String) throws(AssistedCommitError) {
    let mismatch = AssistedCommitError(.unsafeSelection, "\u{201C}\(path)\u{201D} can't be committed this way.")
    guard !path.isEmpty, !path.utf8.contains(0), path.utf8.first != UInt8(ascii: "/") else {
        throw mismatch
    }
    for part in path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
        let name = String(decoding: part, as: UTF8.self)
        if part.isEmpty || name == "." || name == ".." || name.lowercased() == ".git" {
            throw mismatch
        }
    }
}

/// `git rev-parse --path-format=absolute --git-path <name>`: where git
/// keeps `name` for this worktree.
func assistedGitPath(_ root: String, _ name: String) async throws -> String {
    let result = try await git(
        ["rev-parse", "--path-format=absolute", "--git-path", name],
        root,
        "assistedCommitGitPath"
    )
    return POSIXPath.resolve(root, assistedTrimLine(result.stdout))
}

/// The real path of the repository's git directory.
func assistedGitDirectory(_ root: String) async throws -> String {
    let result = try await git(["rev-parse", "--absolute-git-dir"], root, "assistedCommitGitDirectory")
    return try assistedRealPath(assistedTrimLine(result.stdout))
}

/// HEAD as it is now: its branch (refusing symbolic branch aliases and a
/// HEAD that isn't a regular file) and its full commit ID.
func assistedReadHead(_ root: String, gitDirectory: String) async throws -> AssistedCommitHead {
    if let head = try assistedLstat(POSIXPath.join(gitDirectory, "HEAD")), !head.isRegularFile {
        throw AssistedCommitError(.unsafeSelection, "Assisted commits need HEAD to be a regular file.")
    }
    let symbolic = try await git(
        ["symbolic-ref", "--quiet", "--no-recurse", "HEAD"],
        root,
        "assistedCommitReadHead",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    var ref: String?
    if symbolic.exitCode == 0 {
        let name = assistedTrimLine(symbolic.stdout)
        guard JSCompat.startsWith(name, "refs/heads/") else {
            throw AssistedCommitError(.unsafeSelection, "Assisted commits need a branch or a detached HEAD.")
        }
        let alias = try await git(
            ["symbolic-ref", "--quiet", "--no-recurse", name],
            root,
            "assistedCommitReadBranch",
            options: GitExecutionOptions(successExitCodes: [0, 1, 128])
        )
        if alias.exitCode == 0 {
            throw AssistedCommitError(.unsafeSelection, "Assisted commits don't support a branch that points at another branch.")
        }
        ref = name
    }
    let tip = try await git(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"],
        root,
        "assistedCommitReadTip",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    let sha = tip.exitCode == 0 ? assistedTrimLine(tip.stdout) : nil
    if let sha, !assistedIsFullObjectID(sha) {
        throw AssistedCommitError(.unsafeSelection, "HEAD isn't a full commit ID.")
    }
    if ref == nil, sha == nil {
        throw AssistedCommitError(.unsafeSelection, "There's no commit to build on.")
    }
    return AssistedCommitHead(ref: ref, sha: sha)
}

/// The index file at `path` as it is now.
func assistedReadIndexState(_ path: String) throws -> AssistedIndexState {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT {
            return AssistedIndexState(bytes: nil, mode: 0o644, times: nil)
        }
        throw assistedPOSIXError()
    }
    guard info.st_mode & S_IFMT == S_IFREG, let bytes = try assistedReadFile(path) else {
        throw AssistedCommitError(.indexChanged, "The repository's index isn't a regular file.")
    }
    return AssistedIndexState(
        bytes: bytes,
        mode: info.st_mode & 0o777,
        times: (AssistedTimestamp(info.st_atimespec), AssistedTimestamp(info.st_mtimespec))
    )
}

/// Throws `indexChanged` unless the index has `expected`'s bytes.
func assistedVerifyIndex(_ identity: AssistedRepositoryIdentity, _ expected: AssistedIndexState? = nil) throws {
    guard try assistedReadIndexState(identity.indexPath).matches(expected ?? identity.originalIndex) else {
        throw AssistedCommitError(.indexChanged, "The repository's index changed during the assisted commit.")
    }
}

/// Throws `repositoryChanged` unless the repository is the one captured,
/// HEAD names the same branch (with the same bytes), and its tip is
/// `expectedTip`.
func assistedVerifyHead(_ identity: AssistedRepositoryIdentity, _ expectedTip: String?) async throws {
    let changed = AssistedCommitError(
        .repositoryChanged,
        "The branch or the repository changed during the assisted commit."
    )
    guard (try? assistedRealPath(identity.repository.path)) == identity.root,
          (try? await assistedGitDirectory(identity.root)) == identity.gitDirectory
    else {
        throw changed
    }
    let head = try await assistedReadHead(identity.root, gitDirectory: identity.gitDirectory)
    guard head.ref == identity.originalHead.ref, head.sha == expectedTip else {
        throw changed
    }
    if identity.originalHead.ref != nil {
        guard try assistedReadFile(POSIXPath.join(identity.gitDirectory, "HEAD")) == identity.originalHeadBytes else {
            throw changed
        }
    }
}

/// Throws `unsafeSelection` while git is in the middle of something
/// (a merge, rebase, cherry-pick, revert, or bisect), while the index has
/// conflicts, and with replacement refs or grafts, whose history differs
/// from the commits' own.
func assistedEnsureNoRepositoryOperation(_ identity: AssistedRepositoryIdentity) async throws {
    let replacements = try await git(
        ["for-each-ref", "--count=1", "--format=%(refname)", "refs/replace/"],
        identity.root,
        "assistedCommitReplacementRefs"
    )
    let grafts = try assistedLstat(try await assistedGitPath(identity.root, "info/grafts"))
    if !replacements.stdoutData.isEmpty || grafts != nil {
        throw AssistedCommitError(.unsafeSelection, "Assisted commits don't support replacement refs or grafted history.")
    }
    for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG"] {
        if try assistedLstat(POSIXPath.join(identity.gitDirectory, name)) != nil {
            throw AssistedCommitError(.unsafeSelection, "Finish or abort what Git is in the middle of first.")
        }
    }
    let conflicts = try await git(["ls-files", "--unmerged", "-z"], identity.root, "assistedCommitConflicts")
    if !conflicts.stdoutData.isEmpty {
        throw AssistedCommitError(.unsafeSelection, "Resolve the repository's conflicts first.")
    }
}

/// A selected file as it is now: what's at its path, its identity, and its
/// bytes (a symbolic link's target). A file that changes while it's read,
/// or that has an ancestor that isn't a folder, is `selectionChanged`.
func assistedReadSelectedFile(_ root: String, _ path: String) throws -> AssistedCapturedFileState {
    let changed = AssistedCommitError(.selectionChanged, "\u{201C}\(path)\u{201D} changed during the assisted commit.")
    let parts = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    var parent = root
    for part in parts.dropLast() {
        parent = POSIXPath.join(parent, String(decoding: part, as: UTF8.self))
        guard let info = try assistedLstat(parent) else {
            return .missing
        }
        guard info.isDirectory else {
            throw changed
        }
    }
    let absolute = POSIXPath.join(root, path)
    guard let before = try assistedLstat(absolute) else {
        return .missing
    }
    if before.isDirectory {
        return .directory
    }
    guard before.isRegularFile || before.isSymbolicLink else {
        throw AssistedCommitError(.unsafeSelection, "\u{201C}\(path)\u{201D} isn't a file or a symbolic link.")
    }
    let bytes: Data
    do {
        if before.isSymbolicLink {
            bytes = try assistedReadLink(absolute)
        } else {
            guard let contents = try assistedReadFile(absolute) else {
                throw changed
            }
            bytes = contents
        }
    } catch {
        throw changed
    }
    guard let after = try assistedLstat(absolute), after == before else {
        throw changed
    }
    return before.isSymbolicLink ? .symlink(after, bytes) : .file(after, bytes)
}

/// The metadata Espalier keeps for a run in a temporary directory: a
/// private git directory with the repository's effective configuration,
/// its refs, and its HEAD, sharing the repository's objects and working
/// tree, and a private index. Git run here (`run`) never changes the
/// repository's refs or index.
struct AssistedPrivateRepository: Sendable {
    let directory: String
    let identity: AssistedFileIdentity
    let root: String
    let environment: [String: String?]

    /// The private index commits are made in.
    var indexPath: String {
        POSIXPath.join(directory, "index")
    }

    /// `-c core.hooksPath=<an empty folder>`, for the commands that would
    /// otherwise run hooks (`post-index-change`) on private indexes.
    var noHooks: [String] {
        ["-c", "core.hooksPath=\(POSIXPath.join(directory, "no-hooks"))"]
    }

    /// Runs git in the private repository, with `extra` over its
    /// environment.
    @discardableResult
    func run(
        _ args: [String],
        _ name: String,
        env extra: [String: String?] = [:],
        stdin: Data? = nil,
        successExitCodes: Set<Int> = [0]
    ) async throws -> GitResult {
        var env = environment
        env.merge(extra) { $1 }
        return try await git(
            args,
            root,
            name,
            options: GitExecutionOptions(env: env, stdin: stdin, successExitCodes: successExitCodes)
        )
    }

    /// Reads `tree` into the index at `indexPath`.
    func readTree(_ tree: String, into indexPath: String) async throws {
        try await run(noHooks + ["read-tree", tree], "assistedCommitReadTree", env: ["GIT_INDEX_FILE": indexPath])
    }

    /// The tree `base` with `entries` replaced (nil removes the path), made
    /// in the index at `indexPath`.
    func writeTree(_ base: String, _ entries: [(path: String, entry: AssistedTreeEntry?)], indexPath: String) async throws -> String {
        let env: [String: String?] = ["GIT_INDEX_FILE": indexPath]
        try await readTree(base, into: indexPath)
        if !entries.isEmpty {
            let zero = String(repeating: "0", count: base.utf8.count)
            var info = Data()
            for (path, _) in entries {
                info.append(Data("0 \(zero)\t\(path)\0".utf8))
            }
            for (path, entry) in entries {
                if let entry {
                    info.append(Data("\(entry.mode) \(entry.sha)\t\(path)\0".utf8))
                }
            }
            try await run(noHooks + ["update-index", "-z", "--index-info"], "assistedCommitWriteIndex", env: env, stdin: info)
        }
        let tree = try await run(noHooks + ["write-tree"], "assistedCommitWriteTree", env: env)
        return assistedTrimLine(tree.stdout)
    }

    /// Writes `bytes` as a blob, as they are (no filters).
    func hashBlob(_ bytes: Data) async throws -> String {
        let result = try await run(["hash-object", "-w", "--stdin", "--no-filters"], "assistedCommitHashBlob", stdin: bytes)
        return assistedTrimLine(result.stdout)
    }

    /// The blob entries of `tree` at `paths`. A path that's a folder or a
    /// submodule there is `unsafeSelection`.
    func treeEntries(_ tree: String, _ paths: [String]) async throws -> [ExactString: AssistedTreeEntry] {
        guard !paths.isEmpty else {
            return [:]
        }
        let result = try await run(
            ["ls-tree", "-z", "--full-tree", tree, "--"] + literalPathspecs(paths),
            "assistedCommitReadTreeEntries"
        )
        let wanted = Set(paths.map(ExactString.init))
        var entries: [ExactString: AssistedTreeEntry] = [:]
        for record in result.stdoutData.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else {
                throw AssistedCommitError(.unsafeSelection, "Git listed a tree entry Espalier can't read.")
            }
            let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            guard fields.count == 3, wanted.contains(ExactString(path)) else {
                continue
            }
            guard fields[1] == "blob" else {
                throw AssistedCommitError(.unsafeSelection, "\u{201C}\(path)\u{201D} is a folder or a submodule, which assisted commits don't support.")
            }
            entries[ExactString(path)] = AssistedTreeEntry(path: path, mode: String(fields[0]), sha: String(fields[2]))
        }
        return entries
    }

    /// The tree of commit `sha`, or the empty tree for none.
    func tree(of sha: String?) async throws -> String {
        guard let sha else {
            let result = try await run(["mktree"], "assistedCommitEmptyTree", stdin: Data())
            return assistedTrimLine(result.stdout)
        }
        let result = try await run(
            ["rev-parse", "--verify", "--end-of-options", "\(sha)^{tree}"],
            "assistedCommitBaseTree"
        )
        return assistedTrimLine(result.stdout)
    }

    /// The private HEAD's commit, or nil when its branch has none.
    func tip() async throws -> String? {
        let result = try await run(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"],
            "assistedCommitPrivateTip",
            successExitCodes: [0, 1]
        )
        return result.exitCode == 0 ? assistedTrimLine(result.stdout) : nil
    }

    /// Makes the private repository for the repository at `identity`.
    ///
    /// The configuration is the repository's effective configuration,
    /// conditional includes included, flattened into one file (with global
    /// and system configuration off), so includes aren't evaluated again
    /// against the private directory. HEAD has the repository's bytes, so
    /// hooks see the same branch; the refs are a copy, so a commit made here
    /// moves only the copy. Objects are the repository's own.
    static func make(for identity: AssistedRepositoryIdentity) async throws -> AssistedPrivateRepository {
        let (directory, directoryIdentity) = try assistedMakeTemporaryDirectory(prefix: "espalier-assisted-commit-")
        do {
            let environment = try await populate(directory, for: identity)
            return AssistedPrivateRepository(
                directory: directory,
                identity: directoryIdentity,
                root: identity.root,
                environment: environment
            )
        } catch {
            try? assistedRemoveOwnedDirectory(directory, identity: directoryIdentity)
            throw error
        }
    }

    private static func populate(_ directory: String, for identity: AssistedRepositoryIdentity) async throws -> [String: String?] {
        let root = identity.root

        // Without the trampoline, so its credential helper isn't frozen in.
        let config = try await Dugite.exec(
            ["config", "--null", "--list", "--includes"],
            root,
            options: Dugite.ExecutionOptions(env: ["GIT_CONFIG": nil])
        )
        guard config.exitCode == 0 else {
            throw AssistedCommitError(
                .unsafeSelection,
                "Espalier couldn't read the repository's Git configuration.",
                underlying: GitLibError(String(decoding: config.stderr, as: UTF8.self))
            )
        }
        var text = ""
        var hasLFSStorage = false
        for item in config.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            let newline = item.firstIndex(of: UInt8(ascii: "\n"))
            let key = String(decoding: newline.map { item[item.startIndex..<$0] } ?? item[...], as: UTF8.self)
            let value = newline.map { String(decoding: item[item.index(after: $0)...], as: UTF8.self) }
            guard let entry = try configEntry(key, value) else {
                continue
            }
            if key.lowercased() == "lfs.storage" {
                hasLFSStorage = true
            }
            text += entry
        }

        let hooksPath = try await getRepoHooksPath(root)
        text += "[core]\n\tbare = false\n\tsplitIndex = false\n\tfsmonitor = false\n\tuntrackedCache = false\n"
        text += "\thooksPath = \"\(quoteConfigValue(hooksPath))\"\n"
        text += "[extensions]\n\tworktreeConfig = false\n"
        // The private refs must never let git prune objects the
        // repository's refs or other worktrees use.
        text += "[gc]\n\tauto = 0\n\tautoDetach = false\n[maintenance]\n\tauto = false\n"
        if !hasLFSStorage {
            let commonDirectory = try await git(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                root,
                "assistedCommitCommonDirectory"
            )
            let storage = POSIXPath.join(POSIXPath.resolve(root, assistedTrimLine(commonDirectory.stdout)), "lfs")
            text += "[lfs]\n\tstorage = \"\(quoteConfigValue(storage))\"\n"
        }

        let refs = try await git(
            ["for-each-ref", "--format=%(objectname)%00%(refname)%00%(symref)"],
            root,
            "assistedCommitCaptureRefs"
        )
        let objects = try await assistedGitPath(root, "objects")

        try assistedMakeDirectories(POSIXPath.join(directory, "refs"))
        try assistedMakeDirectories(POSIXPath.join(directory, "info"))
        try assistedWriteNewFile(POSIXPath.join(directory, "config"), Data(text.utf8))
        try assistedWriteNewFile(POSIXPath.join(directory, "HEAD"), identity.originalHeadBytes)
        try assistedWriteNewFile(POSIXPath.join(directory, "empty-config"), Data())

        var packedRefs = ""
        for row in refs.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, JSCompat.startsWith(fields[1], "refs/"), !fields[1].contains("..") else {
                throw AssistedCommitError(.unsafeSelection, "Espalier couldn't copy the repository's refs.")
            }
            let (sha, ref, target) = (fields[0], fields[1], fields[2])
            let isPerWorktree = ["refs/bisect/", "refs/worktree/", "refs/rewritten/"].contains { JSCompat.startsWith(ref, $0) }
            if target.isEmpty, !isPerWorktree {
                packedRefs += "\(sha) \(ref)\n"
            } else {
                let path = POSIXPath.join(directory, ref)
                try assistedMakeDirectories(POSIXPath.dirname(path))
                try assistedWriteNewFile(path, Data((target.isEmpty ? "\(sha)\n" : "ref: \(target)\n").utf8))
            }
        }
        try assistedWriteNewFile(POSIXPath.join(directory, "packed-refs"), Data(packedRefs.utf8))

        // Copied as they are: the attributes and excludes git keeps in the
        // git directory, and shallow history's boundary.
        for name in ["info/attributes", "info/exclude", "shallow"] {
            if let bytes = try assistedReadFile(try await assistedGitPath(root, name)) {
                try assistedWriteNewFile(POSIXPath.join(directory, name), bytes)
            }
        }

        let emptyConfig = POSIXPath.join(directory, "empty-config")
        return [
            "GIT_DIR": directory,
            "GIT_COMMON_DIR": directory,
            "GIT_WORK_TREE": root,
            "GIT_INDEX_FILE": POSIXPath.join(directory, "index"),
            "GIT_OBJECT_DIRECTORY": objects,
            "GIT_CONFIG_GLOBAL": emptyConfig,
            "GIT_CONFIG_SYSTEM": emptyConfig,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG": nil,
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_PARAMETERS": "",
            "GIT_SHALLOW_FILE": POSIXPath.join(directory, "shallow"),
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_GRAFT_FILE": POSIXPath.join(directory, "info/grafts"),
            "GIT_NAMESPACE": nil,
        ]
    }

    /// One `git config --list` entry as configuration file text: its own
    /// section header and the key's line. Includes are skipped (`--includes`
    /// expanded them already). A key with no value is a bare `name`, which
    /// git reads as true.
    private static func configEntry(_ key: String, _ value: String?) throws -> String? {
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else {
            throw AssistedCommitError(.unsafeSelection, "Espalier can't copy the Git configuration key \u{201C}\(key)\u{201D}.")
        }
        let section = String(key[..<firstDot])
        if ["include", "includeif"].contains(section.lowercased()) {
            return nil
        }
        let name = String(key[key.index(after: lastDot)...])
        guard isConfigName(section), isConfigName(name) else {
            throw AssistedCommitError(.unsafeSelection, "Espalier can't copy the Git configuration key \u{201C}\(key)\u{201D}.")
        }
        let subsection = firstDot == lastDot ? nil : String(key[key.index(after: firstDot)..<lastDot])
        var text = "[\(section)\(subsection.map { " \"\(quoteConfigValue($0))\"" } ?? "")]\n"
        text += "\t\(name)\(value.map { " = \"\(quoteConfigValue($0))\"" } ?? "")\n"
        return text
    }

    /// Whether `name` is a valid section or key name: a letter, then
    /// letters, digits, and dashes.
    private static func isConfigName(_ name: String) -> Bool {
        guard let first = name.utf8.first, isASCIILetter(first) else {
            return false
        }
        return name.utf8.allSatisfy { isASCIILetter($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

/// `value` escaped for a double-quoted configuration value.
func quoteConfigValue(_ value: String) -> String {
    var quoted = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": quoted += "\\\\"
        case "\"": quoted += "\\\""
        case "\n": quoted += "\\n"
        case "\t": quoted += "\\t"
        default: quoted.unicodeScalars.append(scalar)
        }
    }
    return quoted
}
