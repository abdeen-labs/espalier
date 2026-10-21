// Ported from desktop/app/test/unit/git/lfs-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func writeFile(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: path))
}

@Suite("git-lfs")
struct LFSTests {
    @Suite("isUsingLFS")
    struct IsUsingLFS {
        @Test("returns false for repository not using LFS")
        func notUsingLFS() async throws {
            let path = try setupFixtureRepository("test-repo")
            let repository = Repository(path: path)

            let usingLFS = try await isUsingLFS(repository)
            #expect(!usingLFS)
        }

        @Test("returns true if LFS is tracking a path")
        func tracking() async throws {
            let path = try setupFixtureRepository("test-repo")
            let repository = Repository(path: path)

            _ = try await Dugite.exec(["lfs", "track", "*.psd"], repository.path)

            let usingLFS = try await isUsingLFS(repository)
            #expect(usingLFS)
        }

        @Test("returns false if a non-LFS Git filter is configured")
        func otherFilter() async throws {
            let repository = try setupEmptyRepository()
            let attributesPath = POSIXPath.join(repository.path, ".git", "info", "attributes")

            try writeFile(attributesPath, "* filter=annex\n")

            let usingLFS = try await isUsingLFS(repository)
            #expect(!usingLFS)
        }

        @Test("returns true if LFS tracks a path alongside a non-LFS Git filter")
        func lfsAndOtherFilter() async throws {
            let repository = try setupEmptyRepository()
            let attributesPath = POSIXPath.join(repository.path, ".git", "info", "attributes")

            try writeFile(attributesPath, "* filter=annex\n")
            _ = try await Dugite.exec(["lfs", "track", "*.psd"], repository.path)

            let usingLFS = try await isUsingLFS(repository)
            #expect(usingLFS)
        }
    }

    @Suite("isTrackedByLFS")
    struct IsTrackedByLFS {
        @Test("returns false for repository not using LFS")
        func notUsingLFS() async throws {
            let repository = try setupEmptyRepository()

            let file = "README.md"
            let readme = POSIXPath.join(repository.path, file)
            try writeFile(readme, "Hello world!")

            let found = try await isTrackedByLFS(repository, file)
            #expect(!found)
        }

        @Test("returns true after tracking file", arguments: [
            NamedCase("returns true after tracking file in Git LFS", "README.md"),
            NamedCase(
                "returns true after tracking file with character issues in Git LFS",
                "Top Ten Worst Repositories to host on GitHub - Carlos Mart\u{ED}n Nieto.md"
            ),
        ])
        func tracked(_ testCase: NamedCase<String>) async throws {
            let repository = try setupEmptyRepository()

            let file = testCase.value
            let readme = POSIXPath.join(repository.path, file)
            try writeFile(readme, "Hello world!")

            _ = try await Dugite.exec(["lfs", "track", "*.md"], repository.path)

            let found = try await isTrackedByLFS(repository, file)
            #expect(found)
        }

        // MARK: - Espalier

        @Test("checks a path that starts with a dash")
        func dashedPath() async throws {
            let repository = try setupEmptyRepository()
            _ = try await Dugite.exec(["lfs", "track", "*.md"], repository.path)

            // check-attr mustn't read this path as an option.
            #expect(try await isTrackedByLFS(repository, "-notes.md"))
            #expect(try await !isTrackedByLFS(repository, "-notes.txt"))
        }

        @Test("isn't fooled by a path that contains the filter's output")
        func pathContainingOutput() async throws {
            let repository = try setupEmptyRepository()
            _ = try await Dugite.exec(["lfs", "track", "*.md"], repository.path)

            #expect(try await !isTrackedByLFS(repository, "a: filter: lfs.txt"))
            #expect(try await isTrackedByLFS(repository, "a: filter: lfs.md"))
        }
    }

    @Suite("filesNotTrackedByLFS")
    struct FilesNotTrackedByLFS {
        @Test("returns files not listed in Git LFS")
        func notListed() async throws {
            let repository = try setupEmptyRepository()
            _ = try await Dugite.exec(["lfs", "track", "*.md"], repository.path)

            let videoFile = "some-video-file.mp4"

            let notFound = try await filesNotTrackedByLFS(repository, [videoFile])

            #expect(notFound.count == 1)
            #expect(notFound.contains(videoFile))
        }

        @Test("skips files that are tracked", arguments: [
            NamedCase("skips files that are tracked by Git LFS", (pattern: "*.png", file: "some-cool-photo.png")),
            NamedCase("skips files in a subfolder that are tracked", (pattern: "*.png", file: "app/src/some-cool-photo.png")),
            NamedCase(
                "skips files in a subfolder where the rule only covers the subdirectory",
                (pattern: "app/src/*.png", file: "app/src/some-cool-photo.png")
            ),
        ])
        func skipsTracked(_ testCase: NamedCase<(pattern: String, file: String)>) async throws {
            let (pattern, file) = testCase.value
            let repository = try setupEmptyRepository()
            _ = try await Dugite.exec(["lfs", "track", pattern], repository.path)

            let notFound = try await filesNotTrackedByLFS(repository, [file])

            #expect(notFound.isEmpty)
        }
    }

    // MARK: - Espalier

    @Suite("install")
    struct Install {
        @Test("installs the LFS hooks in a repository")
        func installsHooks() async throws {
            // `git lfs install` also writes the global filters.
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await installLFSHooks(repository, false)

                let hook = POSIXPath.join(repository.path, ".git", "hooks", "pre-push")
                let contents = try String(contentsOfFile: hook, encoding: .utf8)
                #expect(contents.contains("git lfs pre-push"))
            }
        }

        @Test("installs the global LFS filters")
        func installsFilters() async throws {
            try await withIsolatedGitConfig { configPath in
                try await installGlobalLFSFilters(false)

                let config = try String(contentsOfFile: configPath, encoding: .utf8)
                #expect(config.contains("[filter \"lfs\"]"))
                #expect(try await getGlobalConfigValue("filter.lfs.process") == "git-lfs filter-process")
            }
        }
    }

    @Suite("hooks in the way")
    struct HooksInTheWay {
        /// What a test puts at a hook's path.
        enum HookContents: Sendable {
            /// Git LFS's own hook, as the bundled Git LFS installs it.
            case lfs
            /// Git LFS's own hook with its lines indented.
            case lfsIndented
            /// Git LFS's own hook with a line of the repository's added.
            case lfsWithLine(String)
            /// Git LFS's own hook with Windows line endings.
            case lfsWithWindowsLineEndings
            /// Other text.
            case other(String)

            /// The text, where Git LFS's own hook is `lfsHook`.
            func contents(lfsHook: String) -> String {
                switch self {
                case .lfs:
                    lfsHook
                case .lfsIndented:
                    lfsHook.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + String($0) }.joined(separator: "\n")
                case .lfsWithLine(let line):
                    lfsHook + "\n" + line + "\n"
                case .lfsWithWindowsLineEndings:
                    lfsHook.replacingOccurrences(of: "\n", with: "\r\n")
                case .other(let text):
                    text
                }
            }
        }

        /// Git LFS's `name` hook, as the bundled Git LFS installs it.
        private func lfsHook(_ name: String) async throws -> String {
            let scratch = try setupEmptyRepository()
            try await installLFSHooks(scratch, false)
            return try String(contentsOfFile: POSIXPath.join(scratch.path, ".git", "hooks", name), encoding: .utf8)
        }

        @Test("a hook is in the way unless it's Git LFS's own, and Git LFS replaces those that aren't on its own", arguments: [
            NamedCase("Git LFS's pre-push", (hook: "pre-push", contents: HookContents.lfs, isInTheWay: false)),
            NamedCase("Git LFS's post-merge", (hook: "post-merge", contents: .lfs, isInTheWay: false)),
            NamedCase("Git LFS's pre-push, indented", (hook: "pre-push", contents: .lfsIndented, isInTheWay: false)),
            NamedCase("an empty post-checkout", (hook: "post-checkout", contents: .other(""), isInTheWay: false)),
            NamedCase("a post-commit of white space", (hook: "post-commit", contents: .other("  \n\t\n"), isInTheWay: false)),
            NamedCase("an earlier Git LFS's pre-push", (hook: "pre-push", contents: .other("#!/bin/sh\ngit lfs push --stdin $*\n"), isInTheWay: false)),
            NamedCase("an earlier Git LFS's post-merge", (hook: "post-merge", contents: .other(#"""
                #!/bin/sh
                command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting .git/hooks/post-merge.\n"; exit 2; }
                git lfs post-merge "$@"
                """#), isInTheWay: false)),
            NamedCase("the repository's own pre-push", (hook: "pre-push", contents: .other("#!/bin/sh\nnpm test\n"), isInTheWay: true)),
            NamedCase("Git LFS's pre-push with a line added", (hook: "pre-push", contents: .lfsWithLine("npm test"), isInTheWay: true)),
            NamedCase("Git LFS's post-checkout with Windows line endings", (hook: "post-checkout", contents: .lfsWithWindowsLineEndings, isInTheWay: true)),
            NamedCase(
                "a post-checkout like an earlier Git LFS's pre-push",
                (hook: "post-checkout", contents: .other("#!/bin/sh\ngit lfs post-checkout \"$@\"\n"), isInTheWay: true)
            ),
        ])
        func inTheWay(_ testCase: NamedCase<(hook: String, contents: HookContents, isInTheWay: Bool)>) async throws {
            let (hook, contents, isInTheWay) = testCase.value
            // `git lfs install` also writes the global filters.
            try await withIsolatedGitConfig { _ in
                let lfs = try await lfsHook(hook)
                let text = contents.contents(lfsHook: lfs)
                let repository = try setupEmptyRepository()
                let hooksPath = POSIXPath.join(repository.path, ".git", "hooks")
                try FileManager.default.createDirectory(atPath: hooksPath, withIntermediateDirectories: true)
                try writeFile(POSIXPath.join(hooksPath, hook), text)

                let found = try await getHooksInTheWayOfLFS(repository)

                #expect(found == LFSHooksInTheWay(hooksPath: hooksPath, names: isInTheWay ? [hook] : []))
                // Unforced, Git LFS refuses to replace a hook in the way,
                // and replaces the others.
                var installed = true
                do {
                    try await installLFSHooks(repository, false)
                } catch {
                    installed = false
                }
                #expect(installed == !isInTheWay)
            }
        }

        @Test("a link is what it points to; a link to nothing and a folder are in the way")
        func linksAndFolders() async throws {
            try await withIsolatedGitConfig { _ in
                let lfsPostCheckout = try await lfsHook("post-checkout")
                let repository = try setupEmptyRepository()
                let fileManager = FileManager.default
                let hooksPath = POSIXPath.join(repository.path, ".git", "hooks")
                let scripts = POSIXPath.join(repository.path, "scripts")
                try fileManager.createDirectory(atPath: hooksPath, withIntermediateDirectories: true)
                try fileManager.createDirectory(atPath: scripts, withIntermediateDirectories: true)
                try writeFile(POSIXPath.join(scripts, "pre-push"), "#!/bin/sh\nnpm test\n")
                try writeFile(POSIXPath.join(scripts, "post-checkout"), lfsPostCheckout)
                try fileManager.createSymbolicLink(atPath: POSIXPath.join(hooksPath, "pre-push"), withDestinationPath: "../../scripts/pre-push")
                try fileManager.createSymbolicLink(atPath: POSIXPath.join(hooksPath, "post-checkout"), withDestinationPath: "../../scripts/post-checkout")
                try fileManager.createSymbolicLink(atPath: POSIXPath.join(hooksPath, "post-commit"), withDestinationPath: "../../scripts/missing")
                try fileManager.createDirectory(atPath: POSIXPath.join(hooksPath, "post-merge"), withIntermediateDirectories: false)

                let found = try await getHooksInTheWayOfLFS(repository)

                #expect(found.names == ["pre-push", "post-commit", "post-merge"])
            }
        }

        @Test("hooks are looked for where core.hooksPath points")
        func hooksPath() async throws {
            let repository = try setupEmptyRepository()
            try await setConfigValue(repository, "core.hooksPath", ".githooks")
            let fileManager = FileManager.default
            let githooks = POSIXPath.join(repository.path, ".githooks")
            let gitHooks = POSIXPath.join(repository.path, ".git", "hooks")
            try fileManager.createDirectory(atPath: githooks, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: gitHooks, withIntermediateDirectories: true)
            try writeFile(POSIXPath.join(githooks, "post-commit"), "#!/bin/sh\necho committed\n")
            // Git doesn't run this one, and Git LFS doesn't install there.
            try writeFile(POSIXPath.join(gitHooks, "pre-push"), "#!/bin/sh\nnpm test\n")

            let found = try await getHooksInTheWayOfLFS(repository)

            #expect(found == LFSHooksInTheWay(hooksPath: githooks, names: ["post-commit"]))
        }
    }
}
