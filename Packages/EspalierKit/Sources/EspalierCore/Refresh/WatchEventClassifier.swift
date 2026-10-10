import EspalierSupport
import Foundation

/// Decides what a file system event in a watched repository calls for.
///
/// | Path (relative to the git directory or the common directory) | Scope |
/// |---|---|
/// | `HEAD` | status, refs |
/// | `refs/**`, `packed-refs` | refs, status (ahead/behind) |
/// | `index` | status |
/// | `MERGE_HEAD`, `SQUASH_MSG`, `REBASE_HEAD`, `rebase-merge/**`, `rebase-apply/**`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `sequencer/**` | status |
/// | `FETCH_HEAD` | metadata (last fetched only) |
/// | A submodule's `HEAD`, `refs/**`, `packed-refs`, `reftable/**`, `index`, in `modules/<name>/` (a nested one's in `modules/<name>/modules/<name>/`) | status |
/// | `*.lock`, `objects/**`, `logs/**`, `config`, a submodule's other files, everything else | nothing |
/// | Working directory paths outside the git directory | status |
///
/// An event that says events were lost (`mustScanSubDirs`) calls for a full
/// refresh, unless it is confined to a part of the git directory that
/// doesn't count (`objects/`, `logs/`, and a submodule's). An event for a watched directory
/// itself being moved, deleted, or recreated (`rootChanged`), or for a
/// volume mounted or unmounted, calls for a full refresh.
///
/// Paths are compared in their canonically decomposed (NFD) forms, so the
/// form the file system reports never matters. A path inside the git
/// directory counts relative to the git directory, then to the common
/// directory (a linked worktree's git directory is inside the common one).
public enum WatchEventClassifier {
    /// The refresh `event` calls for, or nil when it calls for none.
    public static func scope(for event: FileWatchEvent, in paths: WatchedPaths) -> RefreshScope? {
        scope(for: event, in: NormalizedPaths(paths))
    }

    /// The refresh a batch of events calls for: the union of what each one
    /// calls for, or nil when none calls for anything.
    public static func scope(for events: some Sequence<FileWatchEvent>, in paths: WatchedPaths) -> RefreshScope? {
        let paths = NormalizedPaths(paths)
        var merged: RefreshScope = []
        for event in events {
            if let scope = scope(for: event, in: paths) {
                merged.formUnion(scope)
                if merged == .full {
                    break
                }
            }
        }
        return merged.isEmpty ? nil : merged
    }

    /// The scope for a path relative to the git directory or the common
    /// directory (without a leading slash; `""` is the directory itself).
    static func gitDirectoryScope(forRelativePath relativePath: String) -> RefreshScope? {
        // Git writes `<file>.lock`, then renames it over `<file>`; the rename
        // is the event that counts.
        if JSCompat.endsWith(relativePath, ".lock") {
            return nil
        }

        let firstComponent = JSCompat.split(relativePath, "/")[0]
        switch relativePath {
        case "HEAD":
            return [.status, .refs]
        case "packed-refs":
            return [.refs, .status]
        case "index":
            return .status
        case "MERGE_HEAD", "SQUASH_MSG", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD":
            return .status
        case "FETCH_HEAD":
            return .metadata
        default:
            break
        }

        switch firstComponent {
        // `reftable/` holds every ref in repositories created with
        // `--ref-format=reftable` (Git 3.0's planned default), where `HEAD`
        // and `refs/heads` are placeholders.
        case "refs", "reftable":
            return [.refs, .status]
        case "rebase-merge", "rebase-apply", "sequencer":
            return .status
        case "modules":
            return submoduleScope(forRelativePath: relativePath)
        default:
            return nil
        }
    }

    /// The scope for a path in a submodule's git directory,
    /// `modules/<name>/<path>` (a name may have slashes, and a nested
    /// submodule's git directory is in its parent's `modules/`): the
    /// submodule's `HEAD`, refs, and index are what the parent's status
    /// compares, so a commit or a checkout inside the submodule calls for
    /// the parent's status. Its objects, logs, and other files call for
    /// nothing.
    static func submoduleScope(forRelativePath relativePath: String) -> RefreshScope? {
        let components = JSCompat.split(relativePath, "/")
        // `modules`, then a name, then the path in its git directory.
        guard components.count >= 3 else {
            return nil
        }
        for index in 2..<components.count where components[index - 1] != "logs" {
            switch components[index] {
            case "HEAD", "packed-refs", "index":
                if index == components.count - 1 {
                    return .status
                }
            case "refs", "reftable":
                return .status
            default:
                break
            }
        }
        return nil
    }

    /// Whether events lost under a path relative to the git directory may
    /// have been ones that count: the path counts itself, or it's in the
    /// submodules' git directories (or holds them), outside their objects
    /// and logs.
    static func countsLostEvents(underRelativePath relativePath: String) -> Bool {
        if gitDirectoryScope(forRelativePath: relativePath) != nil {
            return true
        }
        let components = JSCompat.split(relativePath, "/")
        guard components[0] == "modules" else {
            return false
        }
        return !components.dropFirst(2).contains { $0 == "objects" || $0 == "logs" }
    }

    /// `path` in the form classification compares: canonically decomposed,
    /// without trailing slashes.
    static func normalized(_ path: String) -> String {
        var normalized = path.decomposedStringWithCanonicalMapping
        while normalized.utf8.count > 1, JSCompat.endsWith(normalized, "/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// `path` relative to `root` (`""` for the root itself), or nil when
    /// `path` isn't `root` or inside it. Both are normalized.
    static func relativePath(of path: String, under root: String) -> String? {
        if JSCompat.strictEquals(path, root) {
            return ""
        }
        let prefix = JSCompat.endsWith(root, "/") ? root : root + "/"
        guard JSCompat.startsWith(path, prefix) else {
            return nil
        }
        return JSCompat.dropFirst(path, prefix.unicodeScalars.count)
    }

    private struct NormalizedPaths {
        let workingDirectory: String
        let gitDirectory: String
        let commonDirectory: String

        init(_ paths: WatchedPaths) {
            workingDirectory = WatchEventClassifier.normalized(paths.workingDirectory)
            gitDirectory = WatchEventClassifier.normalized(paths.gitDirectory)
            commonDirectory = WatchEventClassifier.normalized(paths.commonDirectory)
        }

        /// Whether `path` is one of the watched directories or contains one.
        func containsWatchedDirectory(_ path: String) -> Bool {
            [workingDirectory, gitDirectory, commonDirectory].contains {
                WatchEventClassifier.relativePath(of: $0, under: path) != nil
            }
        }
    }

    private static func scope(for event: FileWatchEvent, in paths: NormalizedPaths) -> RefreshScope? {
        let flags = event.flags
        if !flags.isDisjoint(with: [.rootChanged, .mount, .unmount]) {
            return .full
        }

        let path = normalized(event.path)
        let mustScan = flags.contains(.mustScanSubDirs)
        if mustScan, paths.containsWatchedDirectory(path) {
            return .full
        }

        if let relative = relativePath(of: path, under: paths.gitDirectory)
            ?? relativePath(of: path, under: paths.commonDirectory) {
            if mustScan {
                return countsLostEvents(underRelativePath: relative) ? .full : nil
            }
            return gitDirectoryScope(forRelativePath: relative)
        }

        if relativePath(of: path, under: paths.workingDirectory) != nil {
            return mustScan ? .full : .status
        }

        return nil
    }
}
