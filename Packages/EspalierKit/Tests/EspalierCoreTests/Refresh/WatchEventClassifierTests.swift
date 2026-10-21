// These check the classifier's rules for paths and the refreshes they call
// for, a path for each rule; the rules for lost events and changed roots;
// and the directories a repository is watched from (`WatchedPaths.roots`,
// which compares paths the classifier's way).

@testable import EspalierCore
import Testing
import TestSupport

/// A main worktree: its git directory, which is also the common directory,
/// is inside the working directory.
private let mainWorktree = WatchedPaths(
    workingDirectory: "/Users/me/src/app",
    gitDirectory: "/Users/me/src/app/.git",
    commonDirectory: "/Users/me/src/app/.git"
)

/// A linked worktree of `mainWorktree`: its git directory is inside the
/// common directory, which holds the refs the worktrees share.
private let linkedWorktree = WatchedPaths(
    workingDirectory: "/Users/me/src/app-feature",
    gitDirectory: "/Users/me/src/app/.git/worktrees/app-feature",
    commonDirectory: "/Users/me/src/app/.git"
)

private let modifiedFile: FileWatchEvent.Flags = [.itemModified, .itemIsFile]

private func scope(
    _ path: String,
    _ flags: FileWatchEvent.Flags = modifiedFile,
    in paths: WatchedPaths = mainWorktree
) -> RefreshScope? {
    WatchEventClassifier.scope(for: FileWatchEvent(path: path, flags: flags, id: 1), in: paths)
}

private func scope(batch paths: [String], in watched: WatchedPaths = mainWorktree) -> RefreshScope? {
    let events = paths.enumerated().map { index, path in
        FileWatchEvent(path: path, flags: modifiedFile, id: UInt64(index + 1))
    }
    return WatchEventClassifier.scope(for: events, in: watched)
}

/// Paths relative to the git directory or the common directory, one for
/// each of the classifier's rules, and the refresh each calls for.
private let gitDirectoryRows: [(String, RefreshScope?)] = [
    ("HEAD", [.status, .refs]),
    ("refs", [.refs, .status]),
    ("refs/heads/main", [.refs, .status]),
    ("packed-refs", [.refs, .status]),
    ("reftable/tables.list", [.refs, .status]),
    ("reftable/tables.list.lock", nil),
    ("index", .status),
    ("MERGE_HEAD", .status),
    ("rebase-merge", .status),
    ("rebase-merge/git-rebase-todo", .status),
    ("sequencer/todo", .status),
    ("FETCH_HEAD", .metadata),
    // Git writes `<file>.lock` and renames it over `<file>`; the rename counts.
    ("index.lock", nil),
    ("refs/heads/main.lock", nil),
    ("objects", nil),
    ("objects/ab/cdef0123456789abcdef0123456789abcdef01", nil),
    ("logs/HEAD", nil),
    ("logs/refs/heads/main", nil),
    ("config", nil),
    // Everything else, and names that only start like the ones above.
    ("", nil),
    ("ORIG_HEAD", nil),
    ("worktrees/other/HEAD", nil),
    ("HEADS", nil),
    ("refsx/heads/main", nil),
    ("index2", nil),
    // A submodule's git directory: what the parent's status compares.
    ("modules/lib/HEAD", .status),
    ("modules/lib/refs/heads/main", .status),
    ("modules/lib/index", .status),
    // A name with slashes, and a nested submodule.
    ("modules/vendor/lib/HEAD", .status),
    ("modules/lib/modules/inner/HEAD", .status),
    // Its writes in progress, objects, logs, and the rest.
    ("modules/lib/HEAD.lock", nil),
    ("modules/lib/objects/ab/cdef0123456789abcdef0123456789abcdef01", nil),
    ("modules/lib/logs/HEAD", nil),
    ("modules/lib/config", nil),
    ("modules/lib/FETCH_HEAD", nil),
    ("modules", nil),
    ("modules/lib", nil),
]

/// Paths of the main worktree's working directory, outside its git
/// directory, and paths outside the repository.
private let workingDirectoryRows: [(String, RefreshScope?)] = [
    ("/Users/me/src/app", .status),
    ("/Users/me/src/app/README.md", .status),
    // Names that mean something only inside the git directory.
    ("/Users/me/src/app/Cargo.lock", .status),
    ("/Users/me/src/app/objects/data.bin", .status),
    ("/Users/me/src/app/HEAD", .status),
    ("/Users/me/src/app/Sources/.git-keep", .status),
    ("/Users/me/src/app/.gitignore", .status),
    ("/Users/me/src/app/.github/workflows/ci.yml", .status),
    // Outside the watched directories.
    ("/Users/me/src/application/README.md", nil),
    ("/Users/me/src/app-feature/README.md", nil),
    ("/Users/me/src/app.git/HEAD", nil),
    ("/Users/me/src", nil),
]

@Suite("WatchEventClassifier")
struct WatchEventClassifierTests {
    @Test("classifies the git directory's paths", arguments: gitDirectoryRows)
    func gitDirectory(relativePath: String, expected: RefreshScope?) {
        #expect(WatchEventClassifier.gitDirectoryScope(forRelativePath: relativePath) == expected)
        #expect(scope("/Users/me/src/app/.git/" + relativePath) == expected)
    }

    @Test("classifies a linked worktree's git directory and the common directory alike", arguments: gitDirectoryRows)
    func linkedWorktreeGitDirectories(relativePath: String, expected: RefreshScope?) {
        #expect(scope("/Users/me/src/app/.git/worktrees/app-feature/" + relativePath, in: linkedWorktree) == expected)
        #expect(scope("/Users/me/src/app/.git/" + relativePath, in: linkedWorktree) == expected)
    }

    @Test("classifies the working directory's paths", arguments: workingDirectoryRows)
    func workingDirectory(path: String, expected: RefreshScope?) {
        #expect(scope(path) == expected)
    }

    @Test("classifies a linked worktree's working directory, not the main worktree's")
    func linkedWorktreeWorkingDirectory() {
        #expect(scope("/Users/me/src/app-feature/README.md", in: linkedWorktree) == .status)
        #expect(scope("/Users/me/src/app-feature", in: linkedWorktree) == .status)
        #expect(scope("/Users/me/src/app/README.md", in: linkedWorktree) == nil)
        // Another worktree's state is in its own directory under the common one.
        #expect(scope("/Users/me/src/app/.git/worktrees/other/index", in: linkedWorktree) == nil)
        #expect(scope("/Users/me/src/app/.git/worktrees/other/HEAD", in: linkedWorktree) == nil)
    }

    @Test("what happened to a path doesn't change its scope")
    func itemFlags() {
        #expect(scope("/Users/me/src/app/.git/HEAD", [.itemRenamed, .itemIsFile]) == [.status, .refs])
        #expect(scope("/Users/me/src/app/.git/refs/heads/topic", [.itemCreated, .itemIsDir]) == [.refs, .status])
        #expect(scope("/Users/me/src/app/.git/index", [.itemRemoved, .itemIsFile, .ownEvent]) == .status)
        #expect(scope("/Users/me/src/app/.git/index.lock", [.itemCreated, .itemRenamed, .itemIsFile]) == nil)
        #expect(scope("/Users/me/src/app/notes", [.itemRemoved, .itemIsDir]) == .status)
        #expect(scope("/Users/me/src/app/link", [.itemCreated, .itemIsSymlink, .itemXattrMod]) == .status)
    }

    @Test(
        "a watched directory that moved, was deleted, or was recreated, and a mount, call for a full refresh",
        arguments: [FileWatchEvent.Flags.rootChanged, .mount, .unmount]
    )
    func rootChanges(flag: FileWatchEvent.Flags) {
        #expect(scope("/Users/me/src/app", flag) == .full)
        #expect(scope("/Users/me/src/app/.git/objects", [flag, .itemIsDir]) == .full)
        #expect(scope("/Users/me/src/app-feature", flag, in: linkedWorktree) == .full)
        #expect(scope("/Volumes/Backup", flag) == .full)
    }

    @Test("lost events call for a full refresh, unless they are confined to the git directory's ignored parts")
    func lostEvents() {
        let lost: FileWatchEvent.Flags = .mustScanSubDirs
        #expect(scope("/Users/me/src/app", lost) == .full)
        #expect(scope("/Users/me/src/app/Sources", lost) == .full)
        #expect(scope("/Users/me/src/app/.git", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/refs/heads", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/rebase-merge", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/FETCH_HEAD", lost) == .full)

        #expect(scope("/Users/me/src/app/.git/objects", lost) == nil)
        #expect(scope("/Users/me/src/app/.git/objects/pack", lost) == nil)
        #expect(scope("/Users/me/src/app/.git/logs/refs", lost) == nil)
        #expect(scope("/Users/me/src/app/.git/hooks", lost) == nil)

        // The submodules' git directories count, but for their objects and
        // logs.
        #expect(scope("/Users/me/src/app/.git/modules", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/modules/lib", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/modules/lib/refs/heads", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/modules/lib/modules/inner", lost) == .full)
        #expect(scope("/Users/me/src/app/.git/modules/lib/objects", lost) == nil)
        #expect(scope("/Users/me/src/app/.git/modules/lib/objects/pack", lost) == nil)
        #expect(scope("/Users/me/src/app/.git/modules/lib/logs/refs", lost) == nil)

        // Lost events under a parent of the watched directories, or reported
        // at the root when the kernel or this process dropped them.
        #expect(scope("/Users/me/src", lost) == .full)
        #expect(scope("/", [.mustScanSubDirs, .kernelDropped]) == .full)
        #expect(scope("/", [.mustScanSubDirs, .userDropped]) == .full)

        #expect(scope("/Users/me/other", lost) == nil)
    }

    @Test("lost events for a linked worktree count where its directories are")
    func lostEventsInLinkedWorktree() {
        let lost: FileWatchEvent.Flags = .mustScanSubDirs
        #expect(scope("/Users/me/src/app/.git/worktrees", lost, in: linkedWorktree) == .full)
        #expect(scope("/Users/me/src/app/.git/worktrees/app-feature", lost, in: linkedWorktree) == .full)
        #expect(scope("/Users/me/src/app/.git/refs/remotes", lost, in: linkedWorktree) == .full)
        #expect(scope("/Users/me/src/app", lost, in: linkedWorktree) == .full)
        #expect(scope("/Users/me/src/app/.git/worktrees/other", lost, in: linkedWorktree) == nil)
        #expect(scope("/Users/me/src/app/.git/objects", lost, in: linkedWorktree) == nil)
    }

    @Test("compares paths in decomposed form, whichever form each side is in")
    func unicodeNormalization() {
        let precomposed = WatchedPaths(
            workingDirectory: "/Users/me/caf\u{E9}",
            gitDirectory: "/Users/me/caf\u{E9}/.git",
            commonDirectory: "/Users/me/caf\u{E9}/.git"
        )
        let decomposed = WatchedPaths(
            workingDirectory: "/Users/me/cafe\u{301}",
            gitDirectory: "/Users/me/cafe\u{301}/.git",
            commonDirectory: "/Users/me/cafe\u{301}/.git"
        )
        #expect(scope("/Users/me/cafe\u{301}/notes.txt", in: precomposed) == .status)
        #expect(scope("/Users/me/caf\u{E9}/notes.txt", in: decomposed) == .status)
        #expect(scope("/Users/me/cafe\u{301}/.git/HEAD", in: precomposed) == [.status, .refs])
        #expect(scope("/Users/me/caf\u{E9}/.git/objects/ab/cd", in: decomposed) == nil)
        #expect(scope("/Users/me/src/app/r\u{E9}sum\u{E9}.txt") == .status)
        #expect(scope("/Users/me/src/app/.git/refs/heads/caf\u{E9}", in: mainWorktree) == [.refs, .status])
        // An ASCII path is never inside a directory whose name isn't.
        #expect(scope("/Users/me/cafe/notes.txt", in: precomposed) == nil)
        #expect(scope("/Users/me/cafe/.git/HEAD", in: decomposed) == nil)
        // A path that isn't ASCII loses its trailing slashes too.
        #expect(scope("/Users/me/caf\u{E9}/.git/refs/heads/", in: decomposed) == [.refs, .status])
    }

    @Test("ignores trailing slashes")
    func trailingSlashes() {
        let paths = WatchedPaths(
            workingDirectory: "/Users/me/src/app/",
            gitDirectory: "/Users/me/src/app/.git/",
            commonDirectory: "/Users/me/src/app/.git//"
        )
        #expect(scope("/Users/me/src/app/.git/HEAD", in: paths) == [.status, .refs])
        #expect(scope("/Users/me/src/app/README.md", in: paths) == .status)
        #expect(scope("/Users/me/src/app/.git/refs/heads/") == [.refs, .status])
        #expect(scope("/Users/me/src/app/.git/objects/") == nil)
    }

    @Test("a batch calls for what its events call for together")
    func batches() {
        #expect(scope(batch: []) == nil)
        #expect(
            scope(batch: [
                "/Users/me/src/app/.git/objects/ab/cdef",
                "/Users/me/src/app/.git/index.lock",
                "/Users/me/src/app/.git/logs/HEAD",
            ]) == nil
        )
        #expect(scope(batch: ["/Users/me/src/app/.git/index", "/Users/me/src/app/.git/FETCH_HEAD"]) == [.status, .metadata])
        #expect(scope(batch: ["/Users/me/src/app/.git/HEAD", "/Users/me/src/app/README.md"]) == [.status, .refs])
        #expect(
            scope(batch: ["/Users/me/src/app/.git/objects/ab/cdef", "/Users/me/src/app/.git/refs/heads/main"])
                == [.refs, .status]
        )

        let events = [
            FileWatchEvent(path: "/Users/me/src/app/.git/FETCH_HEAD", flags: modifiedFile, id: 1),
            FileWatchEvent(path: "/Users/me/src/app", flags: .rootChanged, id: 0),
            FileWatchEvent(path: "/Users/me/src/app/.git/objects/ab", flags: modifiedFile, id: 2),
        ]
        #expect(WatchEventClassifier.scope(for: events, in: mainWorktree) == .full)
    }

    @Suite("WatchedPaths.roots")
    struct Roots {
        @Test("watches each directory not inside another", arguments: [
            NamedCase("watches a main worktree from its working directory", (
                paths: mainWorktree,
                roots: ["/Users/me/src/app"]
            )),
            NamedCase("watches a linked worktree from its working directory and the common directory", (
                paths: linkedWorktree,
                roots: ["/Users/me/src/app-feature", "/Users/me/src/app/.git"]
            )),
            NamedCase("watches a separate git directory on its own", (
                paths: WatchedPaths(
                    workingDirectory: "/Users/me/src/app",
                    gitDirectory: "/Users/me/git/app.git",
                    commonDirectory: "/Users/me/git/app.git"
                ),
                roots: ["/Users/me/src/app", "/Users/me/git/app.git"]
            )),
            NamedCase("keeps a sibling that shares a prefix", (
                paths: WatchedPaths(
                    workingDirectory: "/Users/me/src/app",
                    gitDirectory: "/Users/me/src/app-git",
                    commonDirectory: "/Users/me/src/app-git"
                ),
                roots: ["/Users/me/src/app", "/Users/me/src/app-git"]
            )),
        ])
        func roots(_ testCase: NamedCase<(paths: WatchedPaths, roots: [String])>) {
            #expect(testCase.value.paths.roots == testCase.value.roots)
        }

        @Test("compares forms, but keeps each path as given")
        func normalization() {
            let paths = WatchedPaths(
                workingDirectory: "/Users/me/caf\u{E9}",
                gitDirectory: "/Users/me/cafe\u{301}/.git",
                commonDirectory: "/Users/me/cafe\u{301}/.git"
            )
            let roots = paths.roots
            #expect(roots.count == 1)
            #expect(roots.first?.unicodeScalars.elementsEqual("/Users/me/caf\u{E9}".unicodeScalars) == true)
        }
    }
}
