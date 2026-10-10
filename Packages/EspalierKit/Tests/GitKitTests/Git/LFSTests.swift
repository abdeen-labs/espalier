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
}
