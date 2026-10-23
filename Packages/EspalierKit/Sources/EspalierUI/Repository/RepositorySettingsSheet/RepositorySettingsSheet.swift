// Repository Settings (⌥⌘,): Remote (with the account of a GitHub
// repository), Ignored Files, Git Config, and Fork Behavior for forks; one
// Save that applies what changed in order (the account, the remote's URL,
// the .gitignore, the fork's target, the author) and lists what failed,
// staying open then. Each write is a state-layer intent:
// `updateRepositoryAccount`, `setRemoteURL`, `saveGitIgnore`,
// `setForkContributionTarget`, and `saveGitAuthor`.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// A pane of Repository Settings.
nonisolated enum RepositorySettingsPane: String, CaseIterable, Sendable, Identifiable {
    case remote, ignoredFiles, gitConfig, forkBehavior

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .remote: "Remote"
        case .ignoredFiles: "Ignored Files"
        case .gitConfig: "Git Config"
        case .forkBehavior: "Fork Behavior"
        }
    }
}

/// Repository Settings' state: what each pane shows and what changed.
@MainActor @Observable
final class RepositorySettingsModel {
    @ObservationIgnored let repository: RepositoryModel
    @ObservationIgnored let app: AppModel
    var pane: RepositorySettingsPane = .remote

    // MARK: Remote

    /// The current branch's remote, else the default one, when the sheet
    /// opened.
    let remote: Remote?
    var remoteURL: String

    /// The login of the account chosen for the repository (nil: none), as
    /// it was when the sheet opened until another is chosen.
    var accountLogin: String?

    // MARK: Ignored files

    /// The root .gitignore, or nil when there's none (or until it's read).
    var ignoreText: String? {
        didSet {
            if isLoaded {
                ignoreTextHasChanged = true
            }
        }
    }
    private(set) var ignoreTextHasChanged = false

    // MARK: Git config

    private(set) var gitAuthor: RepositoryGitAuthor?
    var gitConfigLocation: GitConfigLocation = .global {
        didSet {
            guard gitConfigLocation != oldValue, let gitAuthor else {
                return
            }
            if gitConfigLocation == .local, oldValue == .global, authorName.isEmpty, authorEmail.isEmpty {
                authorName = gitAuthor.name(for: .local)
                authorEmail = gitAuthor.email(for: .local)
            }
        }
    }
    /// The local name and email being edited.
    var authorName = ""
    var authorEmail = ""
    /// Whether Other was picked in the email pop-up, whatever the address.
    private var choosesOtherEmail = false

    // MARK: Fork behavior

    var forkTarget: ForkContributionTarget

    // MARK: Status

    private(set) var isLoaded = false
    private(set) var isSaving = false
    /// What failed: reading the .gitignore or the config, or saving.
    private(set) var errors: [String] = []

    init(repository: RepositoryModel, app: AppModel) {
        self.repository = repository
        self.app = app
        let remote = repository.gitState.remotes.currentRemote
        self.remote = remote
        remoteURL = remote?.url ?? ""
        accountLogin = repository.record.accountLogin
        forkTarget = getForkContributionTarget(repository.record)
    }

    /// The API endpoint of the repository's GitHub repository, if it has
    /// one: then it has an account to choose.
    var endpoint: String? {
        repository.record.gitHubRepository?.endpoint
    }

    /// The accounts signed in to the repository's server.
    var accountChoices: [Account] {
        endpoint.map { app.accounts.accounts(onEndpoint: $0) } ?? []
    }

    /// The account the repository has, when it isn't signed in: it's
    /// listed, and can't be chosen again.
    var signedOutLogin: String? {
        guard let login = repository.record.accountLogin, let endpoint,
              app.accounts.account(AccountIdentity(endpoint: endpoint, login: login)) == nil
        else {
            return nil
        }
        return login
    }

    /// Whether another account than the repository's was chosen.
    var accountHasChanged: Bool {
        endpoint != nil && !isSameLogin(accountLogin, repository.record.accountLogin)
    }

    /// The panes: Fork Behavior only for forks.
    var panes: [RepositorySettingsPane] {
        isRepositoryWithForkedGitHubRepository(repository.record) ? RepositorySettingsPane.allCases : [.remote, .ignoredFiles, .gitConfig]
    }

    /// The account chosen for the repository, whose addresses the author
    /// form offers.
    var account: Account? {
        guard let endpoint, let accountLogin else {
            return nil
        }
        return app.accounts.account(AccountIdentity(endpoint: endpoint, login: accountLogin))
    }

    /// Whether the author's name stops Save.
    var authorNameProblem: String? {
        gitConfigLocation == .local && !gitAuthorNameIsValid(authorName) ? invalidGitAuthorNameMessage : nil
    }

    /// The account's addresses the email pop-up offers.
    var authorEmailChoices: [GitAuthorEmailChoice] {
        gitAuthorEmailChoices(for: account.map { [$0] } ?? [])
    }

    /// The email pop-up's choice for the local email: Other once picked, or
    /// for an address that isn't the account's.
    var authorEmailSelection: GitAuthorEmailSelection {
        choosesOtherEmail ? .other : .showing(authorEmail, choices: authorEmailChoices)
    }

    /// Picks from the email pop-up: an account's address becomes the email;
    /// Other keeps the email for the field to edit.
    func selectAuthorEmail(_ selection: GitAuthorEmailSelection) {
        switch selection {
        case .account(let email):
            choosesOtherEmail = false
            authorEmail = email
        case .other:
            choosesOtherEmail = true
        case .none:
            break
        }
    }

    /// Whether commits with the typed local email are attributed to the
    /// account, shown under the email field.
    var authorEmailAttribution: GitEmailAttribution? {
        guard gitConfigLocation == .local, authorEmailChoices.isEmpty || authorEmailSelection == .other else {
            return nil
        }
        return gitEmailAttribution(authorEmail, accounts: account.map { [$0] } ?? [])
    }

    var canSave: Bool {
        isLoaded && !isSaving && authorNameProblem == nil
    }

    /// Reads the .gitignore and the author settings.
    func load() async {
        var errors: [String] = []
        do throws(OperationError) {
            ignoreText = try await repository.readGitIgnore()
        } catch {
            errors.append("Couldn't read .gitignore: \(error.message)")
        }
        do throws(OperationError) {
            let author = try await repository.loadGitAuthor()
            gitAuthor = author
            gitConfigLocation = author.location
            authorName = author.name(for: .local)
            authorEmail = author.email(for: .local)
            choosesOtherEmail = false
        } catch {
            errors.append(error.message)
        }
        self.errors = errors
        isLoaded = true
    }

    /// Saves what changed, in order. Returns whether everything was saved;
    /// otherwise `errors` says what wasn't.
    func save() async -> Bool {
        guard canSave else {
            return false
        }
        isSaving = true
        defer { isSaving = false }
        var errors: [String] = []

        if accountHasChanged {
            do throws(OperationError) {
                try await app.updateRepositoryAccount(repository.id, login: accountLogin)
            } catch {
                errors.append("Couldn't change the account: \(error.message)")
            }
        }

        if let remote {
            do throws(OperationError) {
                try await repository.sync.setRemoteURL(remoteURL, for: remote.name)
            } catch {
                errors.append("Couldn't set the remote URL: \(error.message)")
            }
        }

        if ignoreTextHasChanged, let ignoreText {
            do throws(OperationError) {
                try await repository.saveGitIgnore(ignoreText)
                ignoreTextHasChanged = false
            } catch {
                errors.append("Couldn't save .gitignore: \(error.message)")
            }
        }

        if forkTarget != getForkContributionTarget(repository.record) {
            app.setForkContributionTarget(forkTarget, for: repository.id)
        }

        if let gitAuthor {
            do throws(OperationError) {
                try await repository.saveGitAuthor(gitConfigLocation, name: authorName, email: authorEmail, loaded: gitAuthor)
            } catch {
                errors.append(error.message)
            }
        }

        self.errors = errors
        return errors.isEmpty
    }
}

/// Repository Settings.
struct RepositorySettingsSheet: View {
    static let sheetID = "repository.settings"

    @State var model: RepositorySettingsModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    var body: some View {
        RepositorySettingsForm(model: model, cancel: { dismiss() }, save: save, publish: publish)
            .task {
                if !model.isLoaded {
                    await model.load()
                }
            }
    }

    private func save() {
        let model = model
        Task {
            if await model.save() {
                dismiss()
            }
        }
    }

    /// No remote: Publish, on top of the settings.
    private func publish() {
        PublishRepositorySheet.present(for: model.repository, in: context)
    }

    static func present(for repository: RepositoryModel, in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
        let model = RepositorySettingsModel(repository: repository, app: context.app)
        context.modals.presentSheet(id: sheetID) {
            RepositorySettingsSheet(model: model)
        }
    }
}

/// Repository Settings' form: the panes, then the errors and the buttons.
struct RepositorySettingsForm: View {
    @Bindable var model: RepositorySettingsModel
    var cancel: () -> Void = {}
    var save: () -> Void = {}
    var publish: () -> Void = {}

    var body: some View {
        SheetScaffold("Repository Settings", width: Metrics.Sheet.terminalWidth) {
            // The panes' tabs, centered, as a tab view's.
            CapsuleSegmentedControl(
                "Pane",
                selection: $model.pane,
                segments: model.panes.map { CapsuleSegment($0.title, value: $0) }
            )
            .frame(maxWidth: .infinity)

            // Every pane fits the area's height, so choosing another never
            // resizes the sheet; the panes crossfade (0.15 s). The ignored
            // files' editor fills it.
            Group {
                switch model.pane {
                case .remote:
                    RemotePane(
                        remote: model.remote,
                        url: $model.remoteURL,
                        account: model.endpoint == nil ? nil : RemotePaneAccount(
                            accounts: model.accountChoices,
                            signedOutLogin: model.signedOutLogin,
                            login: $model.accountLogin
                        ),
                        publish: publish
                    )
                case .ignoredFiles:
                    IgnoredFilesPane(text: Binding(get: { model.ignoreText ?? "" }, set: { model.ignoreText = $0 }), isLoaded: model.isLoaded)
                        .frame(height: Metrics.Sheet.listHeight)
                case .gitConfig:
                    GitConfigPane(model: model)
                case .forkBehavior:
                    if let content = ForkSettingsContent(record: model.repository.record, target: model.forkTarget) {
                        ForkBehaviorPane(content: content, target: $model.forkTarget)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(model.pane)
            .transition(.opacity)
            .frame(minHeight: Metrics.Sheet.listHeight, alignment: .top)
            .motion(Motion.leave, value: model.pane)

            ForEach(model.errors, id: \.self) { error in
                FieldMessage(error, kind: .error)
            }
        } buttons: {
            SheetButtons(
                "Save",
                isConfirmDisabled: !model.canSave,
                isWorking: model.isSaving,
                cancel: cancel,
                confirm: save
            )
        }
    }
}
