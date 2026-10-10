// The welcome flow's Configure Git step, a form: "Use my GitHub account
// name and email address" or "Configure manually" when an account is signed
// in, the name and email (`GitAuthorForm`: the account's name and its
// addresses in a pop-up, or typed ones with the attribution check), the
// example commit, and Finish, which writes only what changed through the
// global git settings.
//
// The pop-up offers the account's verified addresses and its private
// noreply one; a name git would reject can't be saved; and a write that
// fails for another reason than the lock file is shown, the flow ending
// anyway so it never traps anyone.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI
import os

private let logger = Log.logger(category: "welcome")

/// The Configure Git step's state.
@MainActor @Observable
final class ConfigureGitModel {
    /// Where the author comes from.
    enum Source: Hashable, Sendable {
        /// The signed-in account's name and an address of its.
        case account
        /// What's typed.
        case manual
    }

    /// A lock file kept git from writing.
    struct LockFile: Equatable {
        let path: String
        let message: String
    }

    @ObservationIgnored let app: AppModel
    @ObservationIgnored let presenter: WindowPresenter
    @ObservationIgnored private let accountOverride: Account??

    var source: Source
    var manualName = ""
    var manualEmail = ""
    /// The account address chosen in the pop-up.
    var accountEmail = ""
    var lockFile: LockFile?
    var isLoaded = false
    private(set) var isSaving = false
    /// The global configuration when the step loaded it.
    private(set) var configured = GlobalGitSettings(name: nil, email: nil, defaultBranch: "main")

    /// - Parameter account: The account to offer; the first signed-in one
    ///   when not given (snapshots pass one).
    init(app: AppModel, presenter: WindowPresenter, account: Account?? = nil) {
        self.app = app
        self.presenter = presenter
        accountOverride = account
        let initial = account ?? app.accounts.accounts.first
        source = initial == nil ? .manual : .account
        if let initial {
            let preferred = lookupPreferredEmail(initial)
            let choices = gitAuthorEmailChoices(for: [initial]).map(\.email)
            // The pop-up's choice: the preferred address when it's offered.
            accountEmail = choices.contains(preferred) || choices.isEmpty ? preferred : choices[0]
            manualName = Self.accountName(initial)
            manualEmail = preferred
        }
    }

    // MARK: Derived

    /// The account whose name and addresses are offered.
    var account: Account? {
        accountOverride ?? app.accounts.accounts.first
    }

    /// "Use my GitHub account name and email address", or "… GitHub
    /// Enterprise account …".
    var accountChoiceTitle: String {
        let kind = account.map(isDotComAccount) == false ? "GitHub Enterprise" : "GitHub"
        return "Use my \(kind) account name and email address"
    }

    /// The name to save.
    var name: String {
        switch source {
        case .account: account.map(Self.accountName) ?? ""
        case .manual: manualName
        }
    }

    /// The email to save.
    var email: String {
        switch source {
        case .account: accountEmail
        case .manual: JSCompat.trim(manualEmail)
        }
    }

    /// The account's addresses: its verified ones and its private noreply
    /// one.
    var emailChoices: [GitAuthorEmailChoice] {
        account.map { gitAuthorEmailChoices(for: [$0]) } ?? []
    }

    /// The problem with the name, if git would reject it.
    var nameProblem: String? {
        gitAuthorNameIsValid(name) ? nil : invalidGitAuthorNameMessage
    }

    /// Whether commits with the typed address are attributed to the
    /// account (shown under a typed address).
    var attribution: GitEmailAttribution? {
        guard source == .manual, let account else {
            return nil
        }
        return gitEmailAttribution(manualEmail, accounts: [account])
    }

    /// Whether Finish can run.
    var canFinish: Bool {
        isLoaded && nameProblem == nil && !isSaving && lockFile == nil
    }

    /// The example commit's author.
    var exampleAuthor: AvatarUser {
        AvatarUser(email: email, avatarURL: nil, name: name, endpoint: account?.endpoint)
    }

    static func accountName(_ account: Account) -> String {
        account.name.isEmpty ? account.login : account.name
    }

    // MARK: Loading and saving

    /// Reads the global author: a configured name and address fill the
    /// manual fields, unless something was typed already.
    func load() async {
        do throws(OperationError) {
            configured = try await app.loadGlobalGitSettings()
        } catch {
            // Nothing to fill in: the fields keep the account's values.
            logger.error("Could not read the global author: \(error.message, privacy: .public)")
        }
        if let name = configured.name, !name.isEmpty, !isEdited(\.manualName) {
            manualName = name
        }
        if let email = configured.email, !email.isEmpty, !isEdited(\.manualEmail) {
            manualEmail = email
        }
        isLoaded = true
    }

    /// Whether a manual field differs from what the account suggested
    /// (the user typed in it before the configuration loaded).
    private func isEdited(_ field: KeyPath<ConfigureGitModel, String>) -> Bool {
        let suggested = field == \ConfigureGitModel.manualName
            ? account.map(Self.accountName) ?? ""
            : account.map(lookupPreferredEmail) ?? ""
        return self[keyPath: field] != suggested
    }

    /// Finish: writes the name and address that differ from the global
    /// configuration (empty ones are left alone), then ends the welcome
    /// flow. Returns false while a lock file is in the way.
    @discardableResult
    func finish() async -> Bool {
        guard canFinish else {
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let name = name
        let email = email
        do throws(OperationError) {
            try await app.setGlobalGitAuthor(name: name.isEmpty ? nil : name, email: email.isEmpty ? nil : email)
        } catch {
            if let path = error.gitConfigLockFilePath, let message = error.gitConfigLockFileMessage {
                lockFile = LockFile(path: path, message: message)
                return false
            }
            // Settings ▸ Git can try again; the flow doesn't trap anyone.
            presenter.present(error)
        }
        app.endWelcomeFlow()
        return true
    }

    /// Deletes the lock file, then finishes again.
    func deleteLockFileAndRetry() async {
        guard let lockFile else {
            return
        }
        do throws(OperationError) {
            try await app.removeGitConfigLockFile(lockFile.path)
        } catch {
            presenter.present(error)
            return
        }
        self.lockFile = nil
        await finish()
    }
}

/// The example commit: how the author will look, as a commit list row
/// with "Fix all the things".
struct ExampleCommitRow: View {
    let author: AvatarUser

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Avatar(author, size: Metrics.Welcome.avatarSize)
            VStack(alignment: .leading, spacing: Metrics.grid / 2) {
                Text("Fix all the things")
                    .font(Typography.row.weight(.medium))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                Text("\(author.name.isEmpty ? "Your Name" : author.name) committed \(RelativeTime.formatRelative(-30 * 60))")
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Configure Git step.
struct ConfigureGitStep: View {
    @Bindable var model: ConfigureGitModel
    var back: @MainActor () -> Void = {}
    /// Whether the step reads the configuration when it appears (snapshots
    /// show fixed values).
    var loadsOnAppear = true

    var body: some View {
        VStack(spacing: Metrics.Welcome.sectionSpacing) {
            WelcomeHeading(
                title: "Configure Git",
                message: "This is used to identify the commits you create. Anyone will be able to see this information if you publish commits."
            )

            VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
                if let lockFile = model.lockFile {
                    // A banner: the modified color's tint, radius 14.
                    VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                        FieldMessage(lockFile.message, kind: .warning)
                        Button("Delete Lock File and Try Again") {
                            Task { await model.deleteLockFileAndRetry() }
                        }
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                    }
                    .padding(Metrics.insetMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Color(espalier: StatusBarTone.attention.fill))
                    )
                }
                Form {
                    if model.account != nil {
                        LabeledContent("Author") {
                            RadioList("Author", selection: $model.source, choices: [
                                ChoiceListItem(model.accountChoiceTitle, value: ConfigureGitModel.Source.account),
                                ChoiceListItem("Configure manually", value: ConfigureGitModel.Source.manual),
                            ])
                        }
                    }
                    author
                }
                .formStyle(.columns)
                VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                    SectionLabel("Example Commit")
                        .padding(.leading, Metrics.grid)
                    ExampleCommitRow(author: model.exampleAuthor)
                        .padding(Metrics.insetMedium)
                        .cardSurface()
                }
            }
            .frame(width: Metrics.Welcome.formWidth)

            HStack(spacing: Metrics.insetSmall) {
                if model.isSaving {
                    ArcProgress(.small)
                        .accessibilityLabel("Saving")
                }
                Spacer()
                Button("Back", action: back)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Finish") {
                    Task { await model.finish() }
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFinish)
            }
            .controlSize(.large)
            .frame(width: Metrics.Welcome.formWidth)
        }
        .padding(Metrics.insetLarge * 2)
        .task {
            if loadsOnAppear {
                await model.load()
            }
        }
    }

    /// The author's rows: the account's name and a pop-up of its addresses,
    /// or the typed name and address.
    @ViewBuilder
    private var author: some View {
        switch model.source {
        case .account:
            GitAuthorForm(
                name: .constant(model.name),
                nameProblem: model.nameProblem,
                emailSelection: Binding {
                    .account(model.accountEmail)
                } set: { selection in
                    if case .account(let email) = selection {
                        model.accountEmail = email
                    }
                },
                otherEmail: .constant(model.accountEmail),
                emailChoices: model.emailChoices,
                isAccountAuthor: true
            )
        case .manual:
            GitAuthorForm(
                name: $model.manualName,
                nameProblem: model.nameProblem,
                emailSelection: .constant(.other),
                otherEmail: $model.manualEmail,
                emailChoices: [],
                attribution: model.attribution
            )
        }
    }
}
