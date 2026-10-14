// These drive the global settings against an isolated global
// configuration (`withIsolatedGitConfig`), and the author form's account
// rules as data.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private let dotCom = testAccount(
    login: "joe",
    id: 1234,
    name: "Joe Bloggs",
    emails: [
        APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .private),
        APIEmail(email: "Joe@Work.example", verified: true, primary: false, visibility: nil),
        APIEmail(email: "unverified@example.com", verified: false, primary: false, visibility: nil),
    ]
)

private let enterprise = testAccount(
    login: "jbloggs",
    endpoint: "https://ghe.example.com/api/v3",
    id: 42,
    name: "",
    emails: [
        APIEmail(email: "joe@work.example", verified: true, primary: true, visibility: .public),
        APIEmail(email: "jbloggs@ghe.example.com", verified: true, primary: false, visibility: .public),
    ]
)

@Suite("Author form rules")
struct GitAuthorFormTests {
    @Test("offers the verified addresses and GitHub.com's private address, without duplicates")
    func emailChoices() {
        let choices = gitAuthorEmailChoices(for: [dotCom])
        #expect(choices.map(\.email) == ["joe@example.com", "Joe@Work.example", "1234+joe@users.noreply.github.com"])
        #expect(choices.allSatisfy { $0.accountSuffix == nil })

        // An enterprise account has no private address offered, and an
        // address both accounts have is offered once, for the first.
        let both = gitAuthorEmailChoices(for: [dotCom, enterprise])
        #expect(both.map(\.email) == [
            "joe@example.com", "Joe@Work.example", "1234+joe@users.noreply.github.com", "jbloggs@ghe.example.com",
        ])
        #expect(both.map(\.account) == [dotCom, dotCom, dotCom, enterprise])
        #expect(gitAuthorEmailChoices(for: []).isEmpty)
    }

    @Test("an address that isn't offered, compared ignoring case, is Other")
    func otherEmail() {
        #expect(isGitAuthorEmailChoice("JOE@example.com", accounts: [dotCom]))
        #expect(isGitAuthorEmailChoice("1234+JOE@users.noreply.github.com", accounts: [dotCom]))
        #expect(!isGitAuthorEmailChoice("unverified@example.com", accounts: [dotCom]))
        #expect(!isGitAuthorEmailChoice("joe@example.com", accounts: []))
    }

    @Test("says whether commits with an address are attributed to the account")
    func attribution() {
        #expect(gitEmailAttribution("joe@example.com", accounts: []) == nil)
        #expect(gitEmailAttribution("  ", accounts: [dotCom]) == nil)

        #expect(gitEmailAttribution("JOE@EXAMPLE.COM", accounts: [dotCom])?.isAttributable == true)
        #expect(gitEmailAttribution("joe@users.noreply.github.com", accounts: [dotCom])?.isAttributable == true)
        #expect(gitEmailAttribution("1234+joe@users.noreply.github.com", accounts: [dotCom])?.isAttributable == true)
        #expect(gitEmailAttribution("unverified@example.com", accounts: [dotCom])?.isAttributable == false)

        #expect(gitEmailAttribution("someone@else.example", accounts: [enterprise])?.isAttributable == false)
        #expect(gitEmailAttribution("jbloggs@ghe.example.com", accounts: [dotCom, enterprise])?.isAttributable == true)
    }

    @Test("fills a missing name or email from the GitHub.com account, else the first")
    func fillsAuthor() {
        let unset = GlobalGitSettings(name: nil, email: "", defaultBranch: "main")
        // The private primary address isn't preferred; with no noreply
        // address listed, GitHub's noreply form is.
        #expect(unset.fillingAuthor(from: [enterprise, dotCom]) == GlobalGitSettings(
            name: "joe",
            email: "1234+joe@users.noreply.github.com",
            defaultBranch: "main"
        ))
        // Without a GitHub.com account, the first; its public primary
        // address is preferred.
        #expect(unset.fillingAuthor(from: [enterprise]) == GlobalGitSettings(name: "jbloggs", email: "joe@work.example", defaultBranch: "main"))
        #expect(unset.fillingAuthor(from: []) == unset)

        let named = GlobalGitSettings(name: "Joe", email: nil, defaultBranch: "trunk")
        #expect(named.fillingAuthor(from: [dotCom]).name == "Joe")
        let complete = GlobalGitSettings(name: "Joe", email: "joe@example.com", defaultBranch: "main")
        #expect(complete.fillingAuthor(from: [dotCom]) == complete)
    }

    @Test("suggests the first account's name, or its login, and its preferred email for the welcome flow")
    func gitHubAuthorInfo() {
        #expect(GitHubAuthorInfo(accounts: []) == nil)
        let info = GitHubAuthorInfo(accounts: [dotCom, enterprise])
        #expect(info?.name == "Joe Bloggs")
        #expect(info?.email == "1234+joe@users.noreply.github.com")
        #expect(GitHubAuthorInfo(accounts: [enterprise])?.name == "jbloggs")
    }

    // These follow git's ident.c, which the rule copies.
    @Test("rejects a name made only of characters git strips, as git does")
    func authorNames() {
        for valid in ["", "Joe Bloggs", "J", " Joe ", "joe.bloggs", "<joe>", "Jöe", "\u{00A0}", "名前", ".,:;<>\"'\\x"] {
            #expect(gitAuthorNameIsValid(valid), "\(valid.debugDescription) should be valid")
        }
        for invalid in [" ", "...", ".,:;<>\"'\\", "\t\n", "\u{0}", " . ", "<>", "\u{20}\u{1F}"] {
            #expect(!gitAuthorNameIsValid(invalid), "\(invalid.debugDescription) should be invalid")
        }
    }
}

@Suite("Global git settings", .offline) @MainActor
struct GlobalGitSettingsTests {
    @Test("loads the global author and default branch, main when unset")
    func loads() async throws {
        try await withIsolatedGitConfig { configPath in
            let app = try await AppHarness().loadedApp()
            #expect(try await app.loadGlobalGitSettings() == GlobalGitSettings(name: nil, email: nil, defaultBranch: "main"))

            try Data("[user]\n\tname = Joe\n\temail = joe@example.com\n[init]\n\tdefaultBranch = trunk\n".utf8)
                .write(to: URL(filePath: configPath))
            #expect(try await app.loadGlobalGitSettings() == GlobalGitSettings(name: "Joe", email: "joe@example.com", defaultBranch: "trunk"))
        }
    }

    @Test("sets the author, leaving out empty values and what's already set")
    func setsAuthor() async throws {
        try await withIsolatedGitConfig { configPath in
            let app = try await AppHarness().loadedApp()

            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: "")
            #expect(try await getGlobalConfigValue("user.name") == "Joe Bloggs")
            #expect(try await getGlobalConfigValue("user.email") == nil)

            try await app.setGlobalGitAuthor(name: nil, email: "joe@example.com")
            #expect(try await app.loadGlobalGitSettings() == GlobalGitSettings(name: "Joe Bloggs", email: "joe@example.com", defaultBranch: "main"))

            // Nothing is written when nothing changes: git replaces the
            // file (a new inode) whenever it writes.
            let written = try fileNumber(configPath)
            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: "joe@example.com")
            try await app.setGlobalGitAuthor(name: "", email: nil)
            #expect(try fileNumber(configPath) == written)
            try await app.setGlobalGitAuthor(name: "Someone Else", email: nil)
            #expect(try fileNumber(configPath) != written)
        }
    }

    @Test("reloads the selected repository's author after setting it")
    func refreshesAuthor() async throws {
        try await withIsolatedGitConfig { _ in
            // Without the test environment's author variables, git commits
            // as the configuration says.
            var runtime = GitRuntime.current
            for variable in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] {
                runtime.processEnvironment[variable] = nil
            }
            try await GitRuntime.withRuntime(runtime) {
                try await setGlobalConfigValue("user.name", "Before")
                try await setGlobalConfigValue("user.email", "before@example.com")
                let local = try setupEmptyRepositoryDefaultMain()
                let harness = try AppHarness()
                let app = await harness.loadedApp()
                let model = try await harness.addAndSelect(local, to: app)
                #expect(model.gitState.commitAuthor?.name == "Before")

                try await app.setGlobalGitAuthor(name: "After", email: "after@example.com")
                await app.idle()

                #expect(model.gitState.commitAuthor?.name == "After")
                #expect(model.gitState.commitAuthor?.email == "after@example.com")
            }
        }
    }

    @Test("sets the default branch of new repositories as git allows it, and nothing when empty or unchanged")
    func setsDefaultBranch() async throws {
        try await withIsolatedGitConfig { _ in
            let app = try await AppHarness().loadedApp()

            #expect(try await app.setDefaultBranchForNewRepositories("main") == nil)
            #expect(try await getGlobalConfigValue("init.defaultBranch") == nil)

            #expect(try await app.setDefaultBranchForNewRepositories("my new~branch") == "my-new-branch")
            #expect(try await getDefaultBranch() == "my-new-branch")

            #expect(try await app.setDefaultBranchForNewRepositories("") == nil)
            #expect(try await app.setDefaultBranchForNewRepositories("my-new-branch") == nil)
            #expect(try await app.setDefaultBranchForNewRepositories("trunk") == "trunk")
            #expect(try await app.loadGlobalGitSettings().defaultBranch == "trunk")
        }
    }

    @Test("names the lock file that kept git from writing, deletes it, and then writes")
    func lockFile() async throws {
        try await withIsolatedGitConfig { configPath in
            let app = try await AppHarness().loadedApp()
            let lockPath = configPath + ".lock"
            try Data().write(to: URL(filePath: lockPath))

            let error = await #expect(throws: OperationError.self) {
                try await app.setGlobalGitAuthor(name: "Joe", email: nil)
            }
            #expect(error?.operation == .setGlobalGitConfig)
            let reported = try #require(error?.gitConfigLockFilePath)
            #expect(realPath(reported) == realPath(lockPath))

            try await app.removeGitConfigLockFile(reported)
            #expect(!FileManager.default.fileExists(atPath: lockPath))
            try await app.removeGitConfigLockFile(reported)
            try await app.setGlobalGitAuthor(name: "Joe", email: nil)
            #expect(try await getGlobalConfigValue("user.name") == "Joe")

            // Only a lock file is deleted.
            let notLock = await #expect(throws: OperationError.self) {
                try await app.removeGitConfigLockFile(configPath)
            }
            #expect(preconditionText(notLock) != nil)
            #expect(FileManager.default.fileExists(atPath: configPath))
            let other = OperationError(.other("x"), operation: .setGlobalGitConfig)
            #expect(other.gitConfigLockFilePath == nil)
        }
    }

    @Test("writes one at a time, in order, so Espalier's writes never meet git's lock")
    func serialWrites() async throws {
        try await withIsolatedGitConfig { _ in
            let app = try await AppHarness().loadedApp()
            let names = (1...12).map { "branch-\($0)" }
            // Each write has asked for its turn before the next one starts,
            // and they all wait at once.
            var writes: [Task<OperationError?, Never>] = []
            for (index, name) in names.enumerated() {
                writes.append(await startWrite { () throws(OperationError) in
                    try await app.setDefaultBranchForNewRepositories(name)
                })
                writes.append(await startWrite { () throws(OperationError) in
                    try await app.setGlobalGitAuthor(name: "Author \(index)", email: "a\(index)@example.com")
                })
            }
            for write in writes {
                if let error = await write.value {
                    Issue.record("A write failed: \(error.message)")
                }
            }
            // Run in the order they were asked for, the last ones win.
            #expect(try await getDefaultBranch() == "branch-12")
            #expect(try await getGlobalConfigValue("user.name") == "Author 11")
            #expect(try await getGlobalConfigValue("user.email") == "a11@example.com")
        }
    }

    // MARK: Global Git LFS filters

    @Test("installs the global Git LFS filters at launch")
    func installsLFSFilters() async throws {
        try await withIsolatedGitConfig { _ in
            let app = try await AppHarness().loadedApp()
            await app.integrations.launchIdle()

            #expect(app.integrations.lfsFiltersError == nil)
            #expect(try await getGlobalConfigValue("filter.lfs.process") == "git-lfs filter-process")
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean -- %f")
        }
    }

    @Test("asks to update global Git LFS filters configured otherwise, and updates them")
    func updatesLFSFilters() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("filter.lfs.clean", "git-lfs clean --other -- %f")
            let app = try await AppHarness().loadedApp()
            await app.integrations.launchIdle()

            let error = try #require(app.integrations.lfsFiltersError)
            #expect(error.reason == .lfsAttributeMismatch)
            #expect(error.operation == .updateLFSFilters)
            #expect(error.recoveries.map(\.kind) == [.updateLFSFilters, .editGlobalGitConfig])
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean --other -- %f")

            let recovery = try #require(error.recoveries.first)
            try await recovery.perform(in: app)

            #expect(app.integrations.lfsFiltersError == nil)
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean -- %f")
        }
    }

    @Test("forgets the launch failure when the user dismisses it")
    func dismissesLFSFiltersError() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("filter.lfs.smudge", "something else")
            let app = try await AppHarness().loadedApp()
            await app.integrations.launchIdle()
            #expect(app.integrations.lfsFiltersError?.reason == .lfsAttributeMismatch)

            app.integrations.dismissLFSFiltersError()
            #expect(app.integrations.lfsFiltersError == nil)
            #expect(try await getGlobalConfigValue("filter.lfs.smudge") == "something else")

            try await app.integrations.updateGlobalLFSFilters()
            #expect(try await getGlobalConfigValue("filter.lfs.smudge") == "git-lfs smudge -- %f")
        }
    }
}

/// The file's inode number.
/// Starts `write` in a task on the main actor and returns once the task has
/// run up to its first suspension: an intent that writes the global
/// configuration has then asked the writer for its turn.
@MainActor
private func startWrite(
    _ write: @escaping @MainActor @Sendable () async throws(OperationError) -> Void
) async -> Task<OperationError?, Never> {
    var task: Task<OperationError?, Never>?
    await withCheckedContinuation { (running: CheckedContinuation<Void, Never>) in
        task = Task { @MainActor in
            running.resume()
            do throws(OperationError) {
                try await write()
                return nil
            } catch {
                return error
            }
        }
    }
    return task!
}

private func fileNumber(_ path: String) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
}

/// The path with symbolic links resolved (the temporary folder is in
/// `/var`, which is `/private/var`).
private func realPath(_ path: String) -> String {
    URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
}
