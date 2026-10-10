// Settings ▸ Git: the author, the default branch, hooks, credentials, and
// the global configuration.
//
// Each value is written to the global configuration when the user commits
// it (picks it, presses Return, or leaves the field), through `AppModel`
// methods. Invalid values are never written: a name made only of characters
// git rejects, a branch name with nothing valid in it, and an empty name or
// email (which revert). A lock file in the way is explained inline, with an
// offer to delete it and try again.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Settings ▸ Git.
public struct GitPane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model, let context {
            GitPaneContent(settings: GitSettingsModel(app: model, presenter: context.presenter))
        } else {
            SettingsPanePlaceholder(tab: .git)
        }
    }
}

/// The Git pane's state: what the global configuration holds, what the
/// user is editing, and a lock file in the way.
@MainActor @Observable
final class GitSettingsModel {
    /// Loading the global configuration.
    enum LoadState: Equatable {
        case loading
        case loaded
        /// Git couldn't read it; the message says why.
        case failed(String)
    }

    /// The default branch choice.
    enum BranchChoice: Hashable, CaseIterable {
        case main, master, other
    }

    /// A lock file kept git from writing: the explanation, and the writes to
    /// try again once it's deleted.
    struct LockFileProblem {
        let path: String
        let message: String
        fileprivate var retries: [Write] = []

        init(path: String, message: String) {
            self.path = path
            self.message = message
        }

        fileprivate init(path: String, message: String, retries: [Write]) {
            self.path = path
            self.message = message
            self.retries = retries
        }
    }

    /// A write of the global configuration, and what to record when it
    /// succeeds.
    fileprivate struct Write {
        let run: @MainActor () async throws(OperationError) -> Void
        let onSuccess: @MainActor () -> Void
    }

    @ObservationIgnored let app: AppModel
    @ObservationIgnored let presenter: WindowPresenter
    @ObservationIgnored private let accountsOverride: [Account]?

    var loadState: LoadState = .loading
    /// What the global configuration holds.
    private(set) var configured = GlobalGitSettings(name: nil, email: nil, defaultBranch: "main")
    /// The name field.
    var name = ""
    /// The email pop-up's choice.
    var emailChoice: GitAuthorEmailSelection = .none
    /// The email field: shown for "Other", or alone without account emails.
    var otherEmail = ""
    var branchChoice: BranchChoice = .main
    /// The branch name field, for "Other".
    var otherBranch = ""
    var lockFile: LockFileProblem?

    /// - Parameters:
    ///   - accounts: The accounts whose emails to offer; the signed-in
    ///     accounts when nil.
    init(app: AppModel, presenter: WindowPresenter, accounts: [Account]? = nil) {
        self.app = app
        self.presenter = presenter
        accountsOverride = accounts
    }

    // MARK: Derived

    /// The accounts whose emails are offered.
    var accounts: [Account] {
        accountsOverride ?? app.accounts.accounts
    }

    /// The account emails the pop-up offers.
    var emailChoices: [GitAuthorEmailChoice] {
        gitAuthorEmailChoices(for: accounts)
    }

    /// Whether the email is a pop-up (there are account emails) rather than
    /// a field alone.
    var showsEmailPopUp: Bool {
        !emailChoices.isEmpty
    }

    /// Whether the email field shows.
    var showsEmailField: Bool {
        !showsEmailPopUp || emailChoice == .other
    }

    /// The name an account suggests while none is configured: the field's
    /// placeholder, since nothing is written until the user commits a value.
    var suggestedName: String? {
        guard (configured.name ?? "").isEmpty else {
            return nil
        }
        return configured.fillingAuthor(from: accounts).name
    }

    /// The problem with the name being typed, if any.
    var nameProblem: String? {
        gitAuthorNameIsValid(name) ? nil : invalidGitAuthorNameMessage
    }

    /// Whether commits with the typed email are attributed to an account
    /// (shown under "Other").
    var attribution: GitEmailAttribution? {
        guard showsEmailField else {
            return nil
        }
        return gitEmailAttribution(otherEmail, accounts: accounts)
    }

    /// What will happen to the branch name being typed: "Will be saved as
    /// <name>." or "<name> is not a valid name."
    var branchNameMessage: (text: String, isError: Bool)? {
        guard branchChoice == .other else {
            return nil
        }
        let sanitized = sanitizedRefName(otherBranch)
        guard !JSCompat.strictEquals(sanitized, otherBranch) else {
            return nil
        }
        if sanitized.isEmpty {
            return ("\(otherBranch) is not a valid name.", true)
        }
        return ("Will be saved as \(sanitized).", false)
    }

    // MARK: Loading

    /// Reads the global configuration and shows it, once the writes asked
    /// for before have finished.
    func load() async {
        await serially { [weak self] in
            guard let self else {
                return
            }
            do throws(OperationError) {
                apply(try await app.loadGlobalGitSettings())
            } catch {
                loadState = .failed(error.message)
            }
        }
    }

    /// Shows `settings` as configured.
    func apply(_ settings: GlobalGitSettings) {
        loadState = .loaded
        configured = settings
        name = settings.name ?? ""
        let email = settings.email ?? ""
        otherEmail = email
        emailChoice = showsEmailPopUp ? .showing(email, choices: emailChoices) : .other
        switch settings.defaultBranch {
        case "main":
            branchChoice = .main
            otherBranch = ""
        case "master":
            branchChoice = .master
            otherBranch = ""
        default:
            branchChoice = .other
            otherBranch = settings.defaultBranch
        }
    }

    // MARK: Committing

    /// Writes the name when it changed and is valid; an empty name reverts.
    func commitName() async {
        let typed = name
        let current = configured.name ?? ""
        guard !JSCompat.strictEquals(typed, current) else {
            return
        }
        guard !typed.isEmpty else {
            name = current
            return
        }
        guard gitAuthorNameIsValid(typed) else {
            return
        }
        await write { [app] () async throws(OperationError) in
            try await app.setGlobalGitAuthor(name: typed, email: nil)
        } onSuccess: { [weak self] in
            self?.configured.name = typed
        }
    }

    /// Picks an email: an account's is written at once; "Other" shows the
    /// field, starting from the current address.
    func selectEmail(_ choice: GitAuthorEmailSelection) async {
        emailChoice = choice
        switch choice {
        case .none:
            break
        case .other:
            if otherEmail.isEmpty {
                otherEmail = configured.email ?? ""
            }
        case .account(let email):
            otherEmail = email
            await writeEmail(email)
        }
    }

    /// Writes the typed email (trimmed) when it changed; an empty one
    /// reverts.
    func commitOtherEmail() async {
        guard showsEmailField else {
            return
        }
        let typed = JSCompat.trim(otherEmail)
        guard !typed.isEmpty else {
            otherEmail = configured.email ?? ""
            return
        }
        if !JSCompat.strictEquals(typed, otherEmail) {
            otherEmail = typed
        }
        await writeEmail(typed)
    }

    private func writeEmail(_ email: String) async {
        guard !JSCompat.strictEquals(email, configured.email ?? "") else {
            return
        }
        await write { [app] () async throws(OperationError) in
            try await app.setGlobalGitAuthor(name: nil, email: email)
        } onSuccess: { [weak self] in
            self?.configured.email = email
        }
    }

    /// Picks the default branch: main and master are written at once;
    /// "Other" shows the field.
    func selectBranch(_ choice: BranchChoice) async {
        branchChoice = choice
        switch choice {
        case .main:
            await writeBranch("main")
        case .master:
            await writeBranch("master")
        case .other:
            if otherBranch.isEmpty, configured.defaultBranch != "main", configured.defaultBranch != "master" {
                otherBranch = configured.defaultBranch
            }
        }
    }

    /// Writes the typed branch name, as git allows it, when something of it
    /// is valid; the field then shows the name saved.
    func commitOtherBranch() async {
        guard branchChoice == .other else {
            return
        }
        let sanitized = sanitizedRefName(otherBranch)
        guard !sanitized.isEmpty else {
            return
        }
        await writeBranch(sanitized)
        if JSCompat.strictEquals(configured.defaultBranch, sanitized), !JSCompat.strictEquals(otherBranch, sanitized) {
            otherBranch = sanitized
        }
    }

    private func writeBranch(_ branch: String) async {
        guard !JSCompat.strictEquals(branch, configured.defaultBranch) else {
            return
        }
        await write { [app] () async throws(OperationError) in
            _ = try await app.setDefaultBranchForNewRepositories(branch)
        } onSuccess: { [weak self] in
            self?.configured.defaultBranch = branch
        }
    }

    /// Commits every field (the pane is going away).
    func commitAll() async {
        await commitName()
        await commitOtherEmail()
        await commitOtherBranch()
    }

    // MARK: Writing

    private func write(
        _ run: @escaping @MainActor () async throws(OperationError) -> Void,
        onSuccess: @escaping @MainActor () -> Void
    ) async {
        await perform(Write(run: run, onSuccess: onSuccess))
    }

    /// Runs a write after what was asked for before. A lock file in the way
    /// is kept, with the write, for `deleteLockFileAndRetry()`; other errors
    /// are shown.
    private func perform(_ write: Write) async {
        await serially { [weak self] in
            do throws(OperationError) {
                try await write.run()
                write.onSuccess()
            } catch {
                guard let self else {
                    return
                }
                guard let path = error.gitConfigLockFilePath, let message = error.gitConfigLockFileMessage else {
                    presenter.present(error)
                    return
                }
                var retries = lockFile?.retries ?? []
                retries.append(write)
                lockFile = LockFileProblem(path: path, message: message, retries: retries)
            }
        }
    }

    /// The last load or write queued.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Runs `work` after everything queued before it, so a reload (the pane
    /// appearing again) never reads the configuration while a write
    /// committed as it went away is still on its way.
    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    /// Deletes the lock file and tries the writes it stopped again.
    func deleteLockFileAndRetry() async {
        guard let problem = lockFile else {
            return
        }
        do throws(OperationError) {
            try await app.removeGitConfigLockFile(problem.path)
        } catch {
            presenter.present(error)
            return
        }
        lockFile = nil
        for write in problem.retries {
            await perform(write)
        }
    }

    /// Opens the global configuration in the editor; its errors (no editor,
    /// say) are shown with their recoveries.
    func editGlobalConfig() async {
        await presenter.perform { [app] _ throws(OperationError) in
            try await app.integrations.editGlobalGitConfig()
        }
    }
}

/// The Git pane: the author, the default branch, hooks, credentials, and
/// the global configuration.
struct GitPaneContent: View {
    @State private var settings: GitSettingsModel
    private let loadsOnAppear: Bool
    /// The branch name field's focus (the author's fields keep their own).
    @FocusState private var focus: Field?

    /// A field the user commits.
    enum Field: Hashable {
        case name, email, branch
    }

    /// - Parameter loadsOnAppear: Whether to read the configuration when
    ///   the pane appears (snapshots apply fixed values instead).
    init(settings: GitSettingsModel, loadsOnAppear: Bool = true) {
        _settings = State(initialValue: settings)
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        @Bindable var settings = settings
        @Bindable var preferences = settings.app.preferences
        SettingsPage {
            if let lockFile = settings.lockFile {
                SettingsSection {
                    SettingsMessageRow {
                        FieldMessage(lockFile.message, kind: .warning)
                    } trailing: {
                        Button("Delete Lock File and Try Again") {
                            Task { await settings.deleteLockFileAndRetry() }
                        }
                        .settingsButton()
                    }
                }
            }

            SettingsSection("Author") {
                switch settings.loadState {
                case .loading:
                    SettingsMessageRow {
                        DelayedProgressView(.small)
                            .frame(maxWidth: .infinity)
                    }
                case .failed(let message):
                    SettingsMessageRow {
                        FieldMessage(message, kind: .error)
                    } trailing: {
                        Button("Try Again") {
                            Task { await settings.load() }
                        }
                        .settingsButton()
                    }
                case .loaded:
                    GitAuthorForm(
                        name: $settings.name,
                        namePrompt: settings.suggestedName ?? "Your Name",
                        nameProblem: settings.nameProblem,
                        emailSelection: emailChoice,
                        otherEmail: $settings.otherEmail,
                        emailChoices: settings.emailChoices,
                        attribution: settings.attribution,
                        layout: .settings
                    ) { field in
                        switch field {
                        case .name: commit(.name)
                        case .email: commit(.email)
                        }
                    }
                }
            }

            SettingsSection("Default branch") {
                SettingsRow("Name for new repositories", description: "GitHub uses main. Some tools still expect master.", labelsControl: true) {
                    CapsuleSegmentedControl("Name for new repositories", selection: branchChoice, segments: [
                        CapsuleSegment("main", value: GitSettingsModel.BranchChoice.main),
                        CapsuleSegment("master", value: GitSettingsModel.BranchChoice.master),
                        CapsuleSegment("Other…", value: GitSettingsModel.BranchChoice.other),
                    ])
                    .fixedSize()
                }
                .disabled(settings.loadState != .loaded)
                if settings.branchChoice == .other {
                    SettingsRow("Branch name", labelsControl: true) {
                        TextField("Branch name", text: $settings.otherBranch, prompt: Text("Branch name"))
                            .labelsHidden()
                            .textFieldStyle(.capsule)
                            .settingsControlWidth()
                            .focused($focus, equals: .branch)
                            .onSubmit { commit(.branch) }
                    } footer: {
                        if let message = settings.branchNameMessage {
                            FieldMessage(message.text, kind: message.isError ? .error : .warning)
                        }
                    }
                    .barTransition()
                }
            }

            SettingsSection("Hooks") {
                SettingsToggleRow(
                    "Load environment variables from your shell",
                    description: "For hooks that need nvm, rbenv, asdf, or other tools your shell sets up.",
                    isOn: $preferences.hooksEnvEnabled
                )
                if preferences.hooksEnvEnabled {
                    SettingsToggleRow(
                        "Cache the shell's variables",
                        description: "Faster hooks. Turn off if your hooks rely on variables that change often.",
                        isOn: $preferences.cacheHooksEnv
                    )
                    .barTransition()
                }
            }

            SettingsSection("Credentials") {
                SettingsToggleRow(
                    "Use Git Credential Manager",
                    description: "Signs you in to private repositories on other hosts, like GitLab, Bitbucket, and Azure DevOps.",
                    isOn: $preferences.useExternalCredentialHelper
                )
            }

            SettingsSection("Global config") {
                SettingsRow("These settings edit your global Git config file") {
                    Button("Edit Global Git Config…") {
                        Task { await settings.editGlobalConfig() }
                    }
                    .settingsButton()
                }
            }
        }
        // Rows a choice shows (the branch name for Other, the cache for
        // the shell's variables, the email field for Other) grow in over
        // 0.22 s and leave over 0.15 s, the rows below moving with them.
        .barMotion(settings.branchChoice == .other)
        .barMotion(preferences.hooksEnvEnabled)
        .barMotion(settings.showsEmailField)
        .task {
            if loadsOnAppear {
                await settings.load()
            }
        }
        .onChange(of: focus) { previous, _ in
            if let previous {
                commit(previous)
            }
        }
        .onDisappear {
            let settings = settings
            Task { await settings.commitAll() }
        }
    }

    private var emailChoice: Binding<GitAuthorEmailSelection> {
        Binding {
            settings.emailChoice
        } set: { choice in
            // The pop-up shows the choice at once; writing takes a moment.
            settings.emailChoice = choice
            let settings = settings
            Task { await settings.selectEmail(choice) }
        }
    }

    private var branchChoice: Binding<GitSettingsModel.BranchChoice> {
        Binding {
            settings.branchChoice
        } set: { choice in
            settings.branchChoice = choice
            let settings = settings
            Task { await settings.selectBranch(choice) }
        }
    }

    private func commit(_ field: Field) {
        let settings = settings
        Task {
            switch field {
            case .name: await settings.commitName()
            case .email: await settings.commitOtherEmail()
            case .branch: await settings.commitOtherBranch()
            }
        }
    }
}
