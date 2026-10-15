// The mark on the fork remotes Espalier adds (`markForkRemote`,
// `getForkRemoteNames`), in real repositories.

import EspalierSupport
import GitKit
import Testing
import TestSupport

private func runGit(_ args: [String], _ repository: Repository) async throws {
    _ = try await git(args, repository.path, "forkRemoteMarkTests")
}

@Suite("Fork remote marks")
struct ForkRemoteMarkTests {
    @Test("marked remotes are read back, whatever their names; other values and unmarked remotes aren't")
    func marks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            #expect(try await getForkRemoteNames(repository).isEmpty)

            for name in ["espalier-octocat", "team/fork", "dotted.name", "Mixed-Case", "espalier-mirror", "off"] {
                try await runGit(["remote", "add", name, "https://github.com/\(name).git"], repository)
            }
            for name in ["espalier-octocat", "team/fork", "dotted.name", "Mixed-Case"] {
                try await markForkRemote(repository, name)
            }
            try await runGit(["config", "remote.off.espalierFork", "false"], repository)

            #expect(try await getForkRemoteNames(repository) == ["espalier-octocat", "team/fork", "dotted.name", "Mixed-Case"].exactSet)
        }
    }

    @Test("a mark in the global configuration doesn't count")
    func globalMark() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await runGit(["remote", "add", "espalier-octocat", "https://github.com/octocat/app.git"], repository)
            try await runGit(["config", "--global", "remote.espalier-octocat.espalierFork", "true"], repository)

            #expect(try await getForkRemoteNames(repository).isEmpty)
        }
    }

    @Test("removing a remote removes its mark; renaming it moves the mark")
    func followsTheRemote() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            for name in ["espalier-a", "espalier-b"] {
                try await runGit(["remote", "add", name, "https://github.com/\(name).git"], repository)
                try await markForkRemote(repository, name)
            }

            try await removeRemote(repository, "espalier-a")
            try await runGit(["remote", "rename", "espalier-b", "fork"], repository)

            #expect(try await getForkRemoteNames(repository) == ["fork"].exactSet)
        }
    }
}
