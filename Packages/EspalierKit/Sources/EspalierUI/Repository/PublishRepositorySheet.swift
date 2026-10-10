// Publish Repository: GitHub.com and GitHub Enterprise (segments only when
// both accounts exist; Enterprise first only without a GitHub.com account),
// the sign-in call to action without an account, Name with "Will be created
// as <name>" when it's sanitized, Description (from .git/description), "Keep
// this code private" (on), and Organization when the account has any.
// Publishing is `publishRepository`; GitHub's errors show in the sheet.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// Where a repository is published: a segment of the sheet.
nonisolated enum PublishDestination: String, CaseIterable, Sendable, Identifiable {
    case gitHub, enterprise

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .gitHub: "GitHub.com"
        case .enterprise: "GitHub Enterprise"
        }
    }
}

/// The Publish sheet's state.
@MainActor @Observable
final class PublishRepositorySheetModel {
    @ObservationIgnored let repository: RepositoryModel
    @ObservationIgnored let app: AppModel
    var destination: PublishDestination
    var name: String
    var description = ""
    var isPrivate = true
    /// The organization's ID, or nil for the account itself.
    var organizationID: Int?
    /// The chosen Enterprise account, among two or more.
    var enterpriseAccount: AccountKey?
    private(set) var organizations: [APIOrganization] = []
    /// The account the organizations are for.
    private(set) var organizationsAccount: AccountKey?
    private(set) var isPublishing = false
    /// GitHub's error, or another reason publishing failed.
    var problem: String?

    init(repository: RepositoryModel, app: AppModel) {
        self.repository = repository
        self.app = app
        name = repository.record.name
        let hasDotCom = app.accounts.accounts.contains { isDotCom($0.endpoint) }
        let hasEnterprise = app.accounts.accounts.contains { !isDotCom($0.endpoint) }
        destination = !hasDotCom && hasEnterprise ? .enterprise : .gitHub
    }

    /// The segments: shown only when both kinds of account exist.
    var destinations: [PublishDestination] {
        let hasDotCom = app.accounts.accounts.contains { isDotCom($0.endpoint) }
        let hasEnterprise = app.accounts.accounts.contains { !isDotCom($0.endpoint) }
        return hasDotCom && hasEnterprise ? PublishDestination.allCases : []
    }

    func accounts(for destination: PublishDestination) -> [Account] {
        switch destination {
        case .gitHub: app.accounts.accounts.filter { isDotCom($0.endpoint) }
        case .enterprise: app.accounts.accounts.filter { !isDotCom($0.endpoint) }
        }
    }

    /// The account to publish with: GitHub.com's, or the chosen Enterprise
    /// one (only the Enterprise choice is stored).
    var account: Account? {
        let accounts = accounts(for: destination)
        if destination == .enterprise, let key = enterpriseAccount, let chosen = accounts.first(where: { AccountKey($0) == key }) {
            return chosen
        }
        return accounts.first
    }

    /// The name the repository gets on GitHub.
    var sanitizedName: String {
        sanitizedRepositoryName(name)
    }

    var organization: APIOrganization? {
        guard let organizationID, organizationsAccount == account.map(AccountKey.init) else {
            return nil
        }
        return organizations.first { $0.id == organizationID }
    }

    var canPublish: Bool {
        account != nil && !sanitizedName.isEmpty && !isPublishing
    }

    /// Loads the description and the account's organizations (the
    /// organizations load again when the account changes).
    func loadDescription() async {
        let loaded = await repository.sync.publishDescription()
        if description.isEmpty {
            description = loaded
        }
    }

    func loadOrganizations() async {
        guard let account else {
            organizations = []
            organizationsAccount = nil
            return
        }
        let key = AccountKey(account)
        let loaded = await repository.sync.publishOrganizations(for: account)
        guard self.account.map(AccountKey.init) == key else {
            return
        }
        organizations = loaded
        organizationsAccount = key
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
            .task(id: model.account.map(AccountKey.init)) {
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
            if !model.destinations.isEmpty {
                // The destinations' tabs, centered, as a tab view's.
                CapsuleSegmentedControl(
                    "Destination",
                    selection: $model.destination,
                    segments: model.destinations.map { CapsuleSegment($0.title, value: $0) }
                )
                .frame(maxWidth: .infinity)
            }

            if let account = model.account {
                fields(for: account)
            } else {
                RepositorySignInPrompt(isEnterprise: model.destination == .enterprise, endpoint: nil)
            }

            if let problem = model.problem {
                FieldMessage(problem, kind: .error)
            }
        } buttons: {
            if model.account != nil {
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

    /// The fields, the same rows for either destination, so switching
    /// destinations never resizes the sheet (the values crossfade, 0.15 s):
    /// Account shows whoever publishes and is a choice only among two or
    /// more Enterprise accounts; Organization is there before the
    /// organizations load, and without any, showing None.
    @ViewBuilder
    private func fields(for account: Account) -> some View {
        Form {
            // The labels in the form's column; the fields are capsules, and
            // the pop-ups as wide as they are.
            let accounts = model.accounts(for: model.destination)
            LabeledContent("Account") {
                CapsulePopUp("Account", selection: Binding(
                    get: { AccountKey(account) },
                    set: { key in
                        if model.destination == .enterprise {
                            model.enterpriseAccount = key
                        }
                    }
                ), title: "@\(account.login) – \(account.friendlyEndpoint)") {
                    ForEach(accounts, id: \.self) { account in
                        Text("@\(account.login) – \(account.friendlyEndpoint)").tag(AccountKey(account))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.destination != .enterprise || accounts.count < 2)
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
                    Text("None").tag(Int?.none)
                    ForEach(model.organizations, id: \.id) { organization in
                        Text(organization.login).tag(Optional(organization.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.organizations.isEmpty)
        }
        .formStyle(.columns)
        .textFieldStyle(.capsule)
        .motion(Motion.leave, value: model.destination)
    }

    /// The organization pop-up's title: the chosen organization's login, or
    /// None.
    private var organizationTitle: String {
        model.organizations.first { $0.id == model.organizationID }?.login ?? "None"
    }
}
