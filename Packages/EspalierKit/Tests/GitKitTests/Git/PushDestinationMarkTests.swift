// The mark on the remotes a push also goes to (`setPushDestination`,
// `getPushDestinationNames`), in real repositories.

import EspalierSupport
import GitKit
import Testing
import TestSupport

private func runGit(_ args: [String], _ repository: Repository) async throws {
    _ = try await git(args, repository.path, "pushDestinationMarkTests")
}

@Suite("Push destination marks")
struct PushDestinationMarkTests {
    @Test("marked remotes are read back, whatever their names; a mark taken off, another value, and a fork's mark aren't")
    func marks() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            #expect(try await getPushDestinationNames(repository).isEmpty)

            for name in ["mirror", "team/backup", "dotted.name", "Mixed-Case", "taken-off", "off", "fork"] {
                try await runGit(["remote", "add", name, "https://example.com/\(name).git"], repository)
            }
            for name in ["mirror", "team/backup", "dotted.name", "Mixed-Case", "taken-off"] {
                try await setPushDestination(repository, name, true)
            }
            try await setPushDestination(repository, "taken-off", false)
            try await runGit(["config", "remote.off.espalierPush", "false"], repository)
            try await markForkRemote(repository, "fork")

            #expect(try await getPushDestinationNames(repository) == ["mirror", "team/backup", "dotted.name", "Mixed-Case"].exactSet)
            #expect(try await getForkRemoteNames(repository) == ["fork"].exactSet)
        }
    }

    @Test("taking the mark off a remote that has none changes nothing")
    func unmarkingTwice() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await runGit(["remote", "add", "mirror", "https://example.com/mirror.git"], repository)

            try await setPushDestination(repository, "mirror", false)
            try await setPushDestination(repository, "mirror", true)
            try await setPushDestination(repository, "mirror", false)
            try await setPushDestination(repository, "mirror", false)

            #expect(try await getPushDestinationNames(repository).isEmpty)
            #expect(try await getRemotes(repository).map(\.name) == ["mirror"])
        }
    }

    @Test("a mark in the global configuration doesn't count")
    func globalMark() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await runGit(["remote", "add", "mirror", "https://example.com/mirror.git"], repository)
            try await runGit(["config", "--global", "remote.mirror.espalierPush", "true"], repository)

            #expect(try await getPushDestinationNames(repository).isEmpty)
        }
    }

    @Test("removing a remote removes its mark; renaming it moves the mark")
    func followsTheRemote() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            for name in ["mirror", "backup"] {
                try await runGit(["remote", "add", name, "https://example.com/\(name).git"], repository)
                try await setPushDestination(repository, name, true)
            }

            try await removeRemote(repository, "mirror")
            try await renameRemote(repository, "backup", "archive")

            #expect(try await getPushDestinationNames(repository) == ["archive"].exactSet)
        }
    }
}
