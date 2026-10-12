// The composer's content from repositories (when the commit button is
// enabled, its branch and shortcut, the summary one file gives, the length
// hint, amending, the last commit, the warnings, their order and links, the
// sparkle's states), and a failed hook that can't be stopped.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Composer", .offline, .hangGuard(minutes: 5)) @MainActor
struct ComposerTests {
    // MARK: The commit button

    @Test("the button sets the branch apart, and shows ⌘↩ only for a commit")
    func button() {
        // The capsule shows the branch apart, so a long one gives way in
        // the middle while the words keep their room.
        #expect(CommitButtonContent(fileCount: 2, branch: "feature/login", isCommitting: true, isEnabled: false).titleParts.branch == "feature/login")
        #expect(CommitButtonContent(fileCount: 2, branch: "main", isEnabled: true).titleParts.branch == "main")
        #expect(CommitButtonContent(fileCount: 2, branch: "main", isGenerating: true, isEnabled: false).titleParts.branch == nil)
        #expect(CommitButtonContent(fileCount: 2, branch: "main", isEnabled: true).showsShortcut)

        // A waiting merge's and other operations' buttons: no ⌘↩.
        #expect(!CommitButtonContent(kind: .merge, fileCount: 0, branch: nil, isEnabled: false).showsShortcut)
        #expect(!CommitButtonContent(kind: .continueOperation(name: "Rebase"), fileCount: 0, branch: nil, isEnabled: true).showsShortcut)
    }

    @Test("the composer follows the repository: files, summary, placeholder, empty commits")
    func fromRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            let commit = repository.commit

            // Three files, no summary: the summary is required.
            var content = ComposerContent.make(repository, app: fixture.app)
            #expect(!content.button.isEnabled)
            #expect(content.author == AuthorIdentityContent(name: "Joe Bloggs", email: "joe.bloggs@somewhere.com"))
            #expect(!content.showsCoAuthorsToggle)
            #expect(content.warning == nil)
            #expect(content.lastCommit == nil)

            commit.draft.summary = "Update the readme"
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.button.isEnabled)

            // No file included.
            repository.changes.setIncludeAll(false)
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(!content.button.isEnabled)

            // An empty commit is allowed.
            commit.options.allowEmpty = true
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.button.isEnabled)
            #expect(content.options.options.allowEmpty)
            commit.options.allowEmpty = false

            // One file names the commit, which then needs no summary.
            repository.changes.setIncluded([try fixture.file("README.md").id], true)
            commit.draft.summary = ""
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.summaryPlaceholder == "Update README.md")
            #expect(content.button.isEnabled)

            // A summary of only spaces doesn't count.
            repository.changes.setIncludeAll(true)
            commit.draft.summary = "   "
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(!content.button.isEnabled)
            await fixture.app.idle()
        }
    }

    @Test("the length hint shows past 50 characters while the setting is on")
    func lengthHint() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let commit = fixture.repository.commit
            commit.draft.summary = String(repeating: "a", count: 50)
            #expect(!ComposerContent.make(fixture.repository, app: fixture.app).showsLengthHint)
            commit.draft.summary += "b"
            #expect(ComposerContent.make(fixture.repository, app: fixture.app).showsLengthHint)
            fixture.app.preferences.showCommitLengthWarning = false
            #expect(!ComposerContent.make(fixture.repository, app: fixture.app).showsLengthHint)
            await fixture.app.idle()
        }
    }

    @Test("after a commit: the last commit with Undo, and amending it")
    func lastCommitAndAmend() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            repository.changes.setIncludeAll(false)
            repository.changes.setIncluded([try fixture.file("README.md").id], true)
            repository.commit.draft.summary = "Update the readme"
            let controller = ComposerController(context: fixture.context, repository: repository)
            fixture.context.state.searchText = "read"
            await controller.commit()
            await fixture.settle()

            // The filter's text clears after a commit.
            #expect(fixture.context.state.searchText.isEmpty)
            var content = ComposerContent.make(repository, app: fixture.app)
            let lastCommit = try #require(content.lastCommit)
            #expect(lastCommit.summary == "Update the readme")
            #expect(lastCommit.isUndoEnabled)
            #expect(controller.canUndo)
            #expect(content.options.canToggleAmend)

            // Amending: the last commit's message, and no last commit shown.
            await controller.toggleAmend()
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.isAmending)
            #expect(content.options.isAmending)
            #expect(content.lastCommit == nil)
            #expect(repository.commit.draft.summary == "Update the readme")
            await controller.toggleAmend()
            #expect(repository.commit.amending == nil)
            await fixture.app.idle()
        }
    }

    @Test("a detached HEAD names no branch; an unborn branch names its own")
    func detachedAndUnborn() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            try await fixture.git(["checkout", "-q", "--detach"])
            await fixture.refresh()
            fixture.repository.commit.draft.summary = "Detached"
            #expect(ComposerContent.make(fixture.repository, app: fixture.app).button.branch == nil)
            // HEAD's commit can be amended, detached or not, from the options
            // and the Commit menu.
            #expect(ComposerContent.make(fixture.repository, app: fixture.app).options.canToggleAmend)
            #expect(fixture.context.actions.canPerform(.toggleAmendLastCommit))

            let unborn = try setupEmptyRepository()
            try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(unborn.path, "new.txt")))
            let empty = try await fixture.harness.addAndSelect(unborn, to: fixture.app)
            await fixture.app.idle()
            let content = ComposerContent.make(empty, app: fixture.app)
            #expect(content.button.branch == "main" || content.button.branch == "master")
            #expect(content.summaryPlaceholder == "Create new.txt")
            // No commit, nothing to amend.
            #expect(!content.options.canToggleAmend)
            await fixture.app.idle()
        }
    }

    // MARK: The author

    @Test("a misattributed email offers the account's addresses, and Update Email sets the global email, which clears the warning")
    func updateEmail() async throws {
        try await withIsolatedGitConfig { _ in
            // Without the test environment's author variables, git commits
            // as the configuration says.
            var runtime = GitRuntime.current
            for variable in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] {
                runtime.processEnvironment[variable] = nil
            }
            try await GitRuntime.withRuntime(runtime) {
                try await setGlobalConfigValue("user.name", "Joe Bloggs")
                try await setGlobalConfigValue("user.email", "joe@work.example.com")
                let (local, _) = try await setupRepositoryWithChanges()
                let fixture = try await ChangesWindowFixture.make(local, accounts: [ChangesFixtures.account])
                let repository = fixture.repository

                // Not on GitHub: no account, no warning, nothing offered.
                var author = AuthorIdentityContent.make(repository, app: fixture.app)
                #expect(author.email == "joe@work.example.com")
                #expect(author.warning == nil)
                #expect(author.accountEmails.isEmpty)

                fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
                author = AuthorIdentityContent.make(repository, app: fixture.app)
                #expect(author.warning == .misattributed(isEnterprise: false))
                // The verified address, then GitHub.com's private one; the
                // preferred one first.
                #expect(author.accountEmails == ["joe@example.com", "1234+joe@users.noreply.github.com"])
                #expect(author.preferredAccountEmail == "joe@example.com")

                let controller = ComposerController(context: fixture.context, repository: repository)
                await controller.updateEmail("1234+joe@users.noreply.github.com")
                await fixture.settle()
                #expect(try await getGlobalConfigValue("user.email") == "1234+joe@users.noreply.github.com")
                #expect(repository.gitState.commitAuthor?.email == "1234+joe@users.noreply.github.com")
                author = AuthorIdentityContent.make(repository, app: fixture.app)
                #expect(author.warning == nil)
                #expect(author.accountEmails.isEmpty)
                #expect(fixture.context.presenter.error == nil)
            }
        }
    }

    // MARK: Warnings

    @Test("the warning is slice F2's, one at a time, linked to the branch's rulesets; failing rules make the commit wait")
    func warnings() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local, accounts: [ChangesFixtures.account])
            let repository = fixture.repository
            let gitHub = repository.gitHub
            #expect(CommitWarning.make(repository) == nil)

            // On GitHub with an account, the rules apply: enforced ones
            // before those the user can bypass.
            fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
            #expect(gitHub.repoRulesEnabled)
            var rules = RepoRulesInfo()
            rules.basicCommitWarning = .bypass
            gitHub.repoRules = rules
            let rulesets = ChangesFixtures.mainRulesets
            #expect(CommitWarning.make(repository) == CommitWarning(.pushRestricted(branch: "main", canBypass: true), rulesURL: rulesets))
            rules.signedCommitsRequired = .enforced
            gitHub.repoRules = rules
            #expect(CommitWarning.make(repository) == CommitWarning(.signedCommitsRequired(branch: "main", canBypass: false), rulesURL: rulesets))

            // A protected branch comes first (with changes); it links no
            // rulesets.
            gitHub.currentBranchProtected = true
            #expect(CommitWarning.make(repository) == CommitWarning(.branchProtected(branch: "main")))

            // No write access comes first of all.
            fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website(.read) }
            #expect(CommitWarning.make(repository) == CommitWarning(.noWriteAccess(repositoryName: "website")))
            #expect(ComposerContent.make(repository, app: fixture.app).warning == CommitWarning(.noWriteAccess(repositoryName: "website")))

            // Rules that fail make the commit wait.
            gitHub.currentBranchProtected = false
            fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
            repository.commit.draft.summary = "Signed?"
            #expect(!ComposerContent.make(repository, app: fixture.app).button.isEnabled)
            gitHub.clearBranchProtection()
            #expect(ComposerContent.make(repository, app: fixture.app).warning == nil)
            #expect(ComposerContent.make(repository, app: fixture.app).button.isEnabled)
            await fixture.settle()
        }
    }

    @Test("the commit message's rules: checked as the composer checks them, shown in the hint, and failing ones make the commit wait")
    func messageRuleCheck() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local, accounts: [ChangesFixtures.account])
            let repository = fixture.repository
            let windowState = ChangesWindowState.of(fixture.context)
            fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
            var rules = RepoRulesInfo()
            rules.commitMessagePatterns.push(RepoRulesMetadataRule(
                enforced: .enforced,
                matcher: { $0.hasPrefix("JIRA-") },
                humanDescription: "must start with \"JIRA-\"",
                rulesetId: 7
            ))
            repository.gitHub.repoRules = rules

            repository.commit.draft.summary = "Fix the loader"
            await windowState.checkMessageRules(repository)
            var content = windowState.composerContent(repository, context: fixture.context)
            let failures = try #require(content.messageRuleFailures)
            #expect(failures.failed == [MessageRuleFailures.Rule(
                "must start with \"JIRA-\"",
                rulesetURL: URL(string: "https://github.com/octo-org/website/rules/7")
            )])
            #expect(failures.rulesetsURL == ChangesFixtures.mainRulesets)
            #expect(!content.button.isEnabled)
            // The rule hint replaces the length hint.
            repository.commit.draft.summary = String(repeating: "a", count: 60)
            await windowState.checkMessageRules(repository)
            content = windowState.composerContent(repository, context: fixture.context)
            #expect(content.messageRuleFailures != nil)
            #expect(!content.showsLengthHint)

            repository.commit.draft.summary = "JIRA-1 Fix the loader"
            await windowState.checkMessageRules(repository)
            content = windowState.composerContent(repository, context: fixture.context)
            #expect(content.messageRuleFailures == nil)
            #expect(content.button.isEnabled)
            await fixture.settle()
        }
    }

    @Test("an unpublished branch whose name fails rules warns before the other rules")
    func publishingRules() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local, accounts: [ChangesFixtures.account])
            try await fixture.git(["checkout", "-q", "-b", "wip/thing"])
            await fixture.refresh()
            fixture.app.updateRecord(fixture.repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
            var rules = RepoRulesInfo()
            rules.creationRestricted = .bypass
            rules.basicCommitWarning = .bypass
            fixture.repository.gitHub.repoRules = rules
            #expect(CommitWarning.make(fixture.repository) == CommitWarning(
                .publishRestricted(branch: "wip/thing", canBypass: true),
                rulesURL: URL(string: "https://github.com/octo-org/website/rules/?ref=refs%2Fheads%2Fwip%2Fthing")
            ))
            await fixture.settle()
        }
    }

    @Test("warnings bold the name, and link the rulesets and the action")
    func warningText() throws {
        let rulesets = ChangesFixtures.mainRulesets
        // "Repository rules" links to the rulesets, then the action.
        let pushing = CommitWarning(.pushRestricted(branch: "main", canBypass: false), rulesURL: rulesets).message
        #expect(pushing.runs.compactMap(\.link) == [rulesets, CommitWarning.switchBranchesURL])
        #expect(CommitWarning(.branchProtected(branch: "main")).message.runs.compactMap(\.link) == [CommitWarning.switchBranchesURL])

        // The name is bold.
        let message = CommitWarning(.pushRestricted(branch: "to", canBypass: true)).message
        let bold = try #require(message.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(String(message[bold.range].characters) == "to")
    }

    @Test("the commit message's rules as the hint shows them, each linked to its ruleset")
    func messageRules() throws {
        let failures = RepoRulesMetadataFailures(
            failed: [RepoRulesMetadataFailure(description: "must start with \"JIRA-\"", rulesetId: 7)],
            bypassed: [RepoRulesMetadataFailure(description: "must not contain \"WIP\"", rulesetId: 8)]
        )
        let hint = try #require(MessageRuleFailures(failures, gitHubRepository: ChangesFixtures.website(), branch: "main"))
        #expect(hint.failed == [MessageRuleFailures.Rule("must start with \"JIRA-\"", rulesetURL: URL(string: "https://github.com/octo-org/website/rules/7"))])
        #expect(hint.bypassed == [MessageRuleFailures.Rule("must not contain \"WIP\"", rulesetURL: URL(string: "https://github.com/octo-org/website/rules/8"))])
        #expect(hint.rulesetsURL == ChangesFixtures.mainRulesets)
        #expect(!hint.canBypass)
        #expect(MessageRuleFailures(RepoRulesMetadataFailures(), gitHubRepository: ChangesFixtures.website(), branch: "main") == nil)
        // Without a GitHub repository or a branch, nothing links.
        let unlinked = try #require(MessageRuleFailures(failures, gitHubRepository: nil, branch: nil))
        #expect(unlinked.rulesetsURL == nil)
        #expect(unlinked.failed.map(\.rulesetURL) == [nil])

        let bypassable = MessageRuleFailures(failed: [], bypassed: [.init("a"), .init("b")])
        #expect(bypassable.canBypass)
    }

    @Test("Undo Commit… (History's commit menu on HEAD, the Commit menu) undoes HEAD's commit, asking first when the tree has changes")
    func undoFromMenus() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            let actions = fixture.context.actions
            #expect(!actions.canPerform(.undoCommit))

            repository.changes.setIncludeAll(false)
            repository.changes.setIncluded([try fixture.file("README.md").id], true)
            repository.commit.draft.summary = "Update the readme"
            await ComposerController(context: fixture.context, repository: repository).commit()
            await fixture.settle()
            let head = try #require(repository.gitState.tip.sha)
            #expect(repository.commit.undoableCommitSHA == head)
            #expect(actions.canPerform(.undoCommit))

            // Two files are still changed: the presenter asks first.
            let task = Task { await actions.performAndWait(.undoCommit) }
            await waitUntil { fixture.context.presenter.confirmation != nil }
            let pending = try #require(fixture.context.presenter.confirmation)
            #expect(pending.confirmation.kind == .undoCommitWithChanges)
            fixture.context.presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))
            await task.value
            await fixture.settle()
            #expect(repository.gitState.tip.sha != head)
            #expect(repository.changes.workingDirectory.files.count == 3)
            #expect(repository.commit.draft.summary == "Update the readme")
            #expect(!actions.canPerform(.undoCommit))
        }
    }

    @Test("VoiceOver hears nothing of a commit cancelled at a gate's question; a failed commit shows git's error, and a retry commits")
    func commitAnnouncements() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            let presenter = fixture.context.presenter
            let recorded = RecordedAnnouncements()
            fixture.context.announcer = recorded.announcer
            let controller = ComposerController(context: fixture.context, repository: repository)
            repository.commit.draft.summary = "Update everything"

            // A question cancelled: nothing ran, nothing is said.
            repository.changes.filter.text = "load"
            let asked = Task { await controller.commit() }
            await waitUntil { presenter.confirmation != nil }
            let pending = try #require(presenter.confirmation)
            #expect(recorded.messages.isEmpty)
            presenter.respond(to: pending.id, with: .cancelled)
            await asked.value
            #expect(recorded.messages.isEmpty)
            repository.changes.filter.text = ""

            // Git fails: its error shows.
            let lock = POSIXPath.join(local.path, ".git/index.lock")
            FileManager.default.createFile(atPath: lock, contents: Data())
            await controller.commit()
            let error = try #require(presenter.error)
            presenter.dismissError(error.id)
            try FileManager.default.removeItem(atPath: lock)
            await fixture.settle()

            await controller.commit()
            await fixture.settle()
            #expect(presenter.error == nil)
            #expect(repository.commit.mostRecentLocalCommit?.summary == "Update everything")
        }
    }

    // MARK: The sparkle

    @Test("the sparkle follows slice G's status, the files, and the draft")
    func sparkle() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let repository = fixture.repository
            let app = fixture.app
            @MainActor func state() -> SparkleState {
                ComposerContent.make(repository, app: app).sparkle
            }

            #expect(state() == .noProvider)
            app.preferences.aiFeaturesEnabled = false
            #expect(state() == .hidden)
            app.preferences.aiFeaturesEnabled = true

            try app.ai.addProvider(Self.provider(models: ["GPT-5", "GPT-5 mini"]))
            #expect(state() == .chooseModel)
            #expect(ComposerContent.make(repository, app: app).modelChoices.map(\.modelName) == ["GPT-5", "GPT-5 mini"])
            let choice = try #require(app.ai.availableModels.first)
            app.ai.select(model: choice.key, for: .commitMessageGeneration)
            // Consent is asked when the sparkle is clicked.
            #expect(state() == .ready(model: "GPT-5"))

            repository.changes.setIncludeAll(false)
            #expect(state() == .noFiles(model: "GPT-5"))
            #expect(!state().isEnabled)
            repository.changes.setIncludeAll(true)

            repository.commit.draft.generatedByAI = true
            #expect(state() == .generated(model: "GPT-5"))
            repository.commit.draft.generatedByAI = false

            repository.ai.commitMessageGeneration = .generating
            #expect(state() == .generating)
            #expect(!ComposerContent.make(repository, app: app).button.isEnabled)
            #expect(ComposerContent.make(repository, app: app).isReadOnly)

            // A failure shows under the fields, with what to do.
            let failure = OperationError(.ai(.provider(title: nil, message: "The model is overloaded.")), operation: .generateCommitMessage)
            repository.ai.commitMessageGeneration = .failed(failure)
            #expect(ComposerContent.make(repository, app: app).aiFailure == AIFailureContent(message: "The model is overloaded.", recovery: .tryAgain))
            let setup = OperationError(.ai(.modelSelectionRequired), operation: .generateCommitMessage, recoveries: [.openSettings(.ai)])
            #expect(AIFailureContent(setup).recovery == .openSettings)
            repository.ai.commitMessageGeneration = .idle
            await app.idle()
        }
    }

    @Test("the sparkle's click: setup, the model choice, then generating")
    func generateFlow() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let controller = ComposerController(context: fixture.context, repository: fixture.repository)
            let state = ChangesWindowState.of(fixture.context)

            await controller.generate()
            #expect(state.sparklePopover == .setup)

            try fixture.app.ai.addProvider(Self.provider(models: ["One", "Two"]))
            await controller.generate()
            #expect(state.sparklePopover == .chooseModel)

            // With AI off, the menu item and its shortcut are gone.
            #expect(!fixture.context.actions.isHidden(.generateCommitMessage))
            fixture.app.preferences.aiFeaturesEnabled = false
            #expect(fixture.context.actions.isHidden(.generateCommitMessage))
            #expect(!fixture.context.actions.canPerform(.generateCommitMessage))
            await fixture.app.idle()
        }
    }

    // MARK: Hooks

    @Test("a failed hook can't be stopped")
    func failedHook() {
        #expect(!HookActivityContent(hookName: "commit-msg", status: .failed).canStop)
    }

    // MARK: Helpers

    /// A provider with models (no secret needed).
    static func provider(models: [String]) -> BYOKProvider {
        BYOKProvider(
            id: "provider-1",
            name: "Local Models",
            type: .openai,
            baseUrl: "http://localhost:11434/v1",
            authKind: .none,
            models: models.map { BYOKModel(id: $0.lowercased().replacingOccurrences(of: " ", with: "-"), name: $0) }
        )
    }
}
