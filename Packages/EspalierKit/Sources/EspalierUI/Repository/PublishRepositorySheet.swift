// Publish Repository: the account, from every signed-in account by host
// (GitHub.com's first, then each GitHub Enterprise host's); it starts on the
// repository's assigned account when it's signed in, else on the only
// account, else on none, and Publish waits for one. Without an account, the
// sign-in call to action, whose new account is chosen. Then Name with "Will
// be created as <name>" when it's sanitized, Description (from
// .git/description), "Keep this code private" (on), and Organization when the
// account has any; another account forgets the organization chosen.
// Publishing is `publishRepository`; GitHub's errors show in the sheet.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The Publish sheet's state.
@MainActor @Observable
final class PublishRepositorySheetModel {
    @ObservationIgnored let repository: RepositoryModel
    @ObservationIgnored let app: AppModel
    var name: String
    var description = ""
    var isPrivate = true
    /// The organization's ID, or nil for the account itself.
    var organizationID: Int?
    /// The account chosen, if any.
    private(set) var chosenAccount: AccountIdentity?
    private(set) var organizations: [APIOrganization] = []
    /// The account the organizations are for.
    private(set) var organizationsAccount: AccountIdentity?
    private(set) var isPublishing = false
    /// GitHub's error, or another reason publishing failed.
    var problem: String?

    init(repository: RepositoryModel, app: AppModel) {
        self.repository = repository
        self.app = app
        name = repository.record.name
        let accounts = app.accounts.accounts
        if let assigned = app.accounts.account(for: repository.record) {
            chosenAccount = assigned.identity
        } else if accounts.count == 1 {
            chosenAccount = accounts[0].identity
        }
    }

    /// The signed-in accounts, as the pop-up lists them.
    var accounts: [Account] {
        groupAccountsForPicker(app.accounts.accounts).flatMap(\.accounts)
    }

    /// The account to publish with: the one chosen, while it's signed in;
    /// else the only one signed in.
    var account: Account? {
        let accounts = accounts
        if let chosenAccount, let chosen = accounts.first(where: { $0.identity == chosenAccount }) {
            return chosen
        }
        return accounts.count == 1 ? accounts[0] : nil
    }

    /// Chooses the account to publish with. The organization chosen was the
    /// other account's, and goes.
    func chooseAccount(_ identity: AccountIdentity?) {
        guard identity != account?.identity else {
            return
        }
        chosenAccount = identity
        organizationID = nil
    }

    /// The name the repository gets on GitHub.
    var sanitizedName: String {
        sanitizedRepositoryName(name)
    }

    /// The organization chosen, when it's the account's.
    var organization: APIOrganization? {
        guard let organizationID, organizationsAccount == account?.identity else {
            return nil
        }
        return organizations.first { $0.id == organizationID }
    }

    var canPublish: Bool {
        account != nil && !sanitizedName.isEmpty && !isPublishing
    }

    /// Loads the description.
    func loadDescription() async {
        let loaded = await repository.sync.publishDescription()
        if description.isEmpty {
            description = loaded
        }
    }

    /// Loads the account's organizations (again when the account changes);
    /// an answer for an account no longer chosen is dropped.
    func loadOrganizations() async {
        guard let account else {
            organizations = []
            organizationsAccount = nil
            organizationID = nil
            return
        }
        let identity = account.identity
        if organizationsAccount != identity {
            organizations = []
            organizationsAccount = nil
        }
        let loaded = await repository.sync.publishOrganizations(for: account)
        guard self.account?.identity == identity else {
            return
        }
        organizations = loaded
        organizationsAccount = identity
        if let organizationID, !loaded.contains(where: { $0.id == organizationID }) {
            self.organizationID = nil
        }
    }

    /// Publishes. GitHub's errors become `problem`.
    func publish(presenter: WindowPresenter) async -> Bool {
        guard canPublish, let account else {
            return false
        }
        problem = nil
        isPublishing = true
        defer { isPublishing = false }
        let request = PublishRepositoryRequest(
            name: sanitizedName,
            description: description,
            isPrivate: isPrivate,
            account: account,
            organization: organization
        )
        let sync = repository.sync
        do throws(OperationError) {
            let published = try await presenter.performThrowing { _ throws(OperationError) in
                try await sync.publishRepository(request)
            }
            return published != nil
        } catch {
            problem = error.message
            return false
        }
    }
}

/// The Publish sheet.
struct PublishRepositorySheet: View {
    static let sheetID = "repository.publish"

    @State var model: PublishRepositorySheetModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    var body: some View {
        PublishRepositoryForm(model: model, cancel: { dismiss() }, publish: publish)
            .task {
                await model.loadDescription()
            }
            .task(id: model.account?.identity) {
                await model.loadOrganizations()
            }
    }

    private func publish() {
        let model = model
        let presenter = context.presenter
        Task {
            if await model.publish(presenter: presenter) {
                dismiss()
            }
        }
    }

    static func present(for repository: RepositoryModel, in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
        let model = PublishRepositorySheetModel(repository: repository, app: context.app)
        context.modals.presentSheet(id: sheetID) {
            PublishRepositorySheet(model: model)
        }
    }
}

/// The Publish sheet's form.
struct PublishRepositoryForm: View {
    @Bindable var model: PublishRepositorySheetModel
    var cancel: () -> Void = {}
    var publish: () -> Void = {}

    var body: some View {
        SheetScaffold("Publish Repository") {
            if model.accounts.isEmpty {
                AccountsSignInPrompt { account in
                    model.chooseAccount(account.identity)
                }
            } else {
                fields
            }

            if let problem = model.problem {
                FieldMessage(problem, kind: .error)
            }
        } buttons: {
            if !model.accounts.isEmpty {
                SheetButtons(
                    "Publish Repository",
                    isConfirmDisabled: !model.canPublish,
                    isWorking: model.isPublishing,
                    cancel: cancel,
                    confirm: publish
                )
            } else {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(model.isPublishing)
    }

    /// The fields: Account, from every signed-in account; Organization is
    /// there before the organizations load, and without any, showing None.
    private var fields: some View {
        Form {
            // The labels in the form's column; the fields are capsules, and
            // the pop-ups as wide as they are.
            LabeledContent("Account") {
                AccountPicker(accounts: model.accounts, selection: Binding(
                    get: { model.account?.identity },
                    set: { model.chooseAccount($0) }
                ))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledContent("Name") {
                TextField("Name", text: $model.name)
                    .labelsHidden()
            }
            if !model.name.isEmpty, model.sanitizedName != model.name {
                FieldMessage("Will be created as \(model.sanitizedName)", kind: .warning)
            }
            LabeledContent("Description") {
                TextField("Description", text: $model.description)
                    .labelsHidden()
            }
            Toggle("Keep this code private", isOn: $model.isPrivate)
                .toggleStyle(.checkboxMark)
            LabeledContent("Organization") {
                CapsulePopUp("Organization", selection: $model.organizationID, title: organizationTitle) {
                    MenuChoice("None", value: Int?.none)
                    for organization in model.organizations {
                        MenuChoice(organization.login, value: Optional(organization.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.organizations.isEmpty)
        }
        .formStyle(.columns)
        .textFieldStyle(.capsule)
    }

    /// The organization pop-up's title: the chosen organization's login, or
    /// None.
    private var organizationTitle: String {
        model.organizations.first { $0.id == model.organizationID }?.login ?? "None"
    }
}
