// Clone a Repository (⇧⌘O): GitHub.com, GitHub Enterprise, and URL, each with
// its own URL, path, filter, selection, and problem; the account picker with
// two or more accounts; the local path that follows the URL
// (`clonePath(_:afterURLChangeFrom:to:)`) and its checks
// (`validateClonePath`); and Clone, which resolves what to clone
// (`resolveCloneInfo`), closes the sheet, and clones. The GitHub.com segment
// is always there (its call to action signs in); the Enterprise segment
// shows once an Enterprise account exists.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Where a clone comes from: a segment of the sheet.
nonisolated enum CloneSource: String, CaseIterable, Sendable, Identifiable {
    case gitHub, enterprise, url

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .gitHub: "GitHub.com"
        case .enterprise: "GitHub Enterprise"
        case .url: "URL"
        }
    }
}

/// The Clone sheet's state: one set of fields per source.
@MainActor @Observable
final class CloneSheetModel {
    /// One source's fields.
    struct Fields: Equatable {
        var url = ""
        var path: String
        /// Why it can't be cloned: the path's problem, or what resolving the
        /// URL found.
        var problem: String?
        var filter = ""
        var selection: CloneableRepositoryListItem.ID?
        /// The chosen account, among two or more.
        var account: AccountKey?
    }

    @ObservationIgnored let app: AppModel
    /// The link that asked for the clone, if one did.
    @ObservationIgnored let externalRequest: ExternalCloneRequest?
    /// The folder clones start in: the last one used.
    let initialPath: String

    var source: CloneSource {
        didSet {
            if source != oldValue {
                onSourceChange?(source)
            }
        }
    }
    private(set) var fields: [CloneSource: Fields] = [:]
    /// Clone is resolving what to clone.
    private(set) var isResolving = false
    @ObservationIgnored var onSourceChange: ((CloneSource) -> Void)?

    /// - Parameters:
    ///   - initialURL: Opens on URL with it (Get Started, links).
    ///   - savedSource: The source the sheet was last on.
    init(app: AppModel, initialURL: String? = nil, externalRequest: ExternalCloneRequest? = nil, savedSource: CloneSource? = nil) {
        self.app = app
        self.externalRequest = externalRequest
        initialPath = app.preferences.lastCloneLocation
        source = .gitHub
        for source in CloneSource.allCases {
            fields[source] = Fields(path: initialPath)
        }
        if let initialURL, !initialURL.isEmpty {
            source = .url
            setURL(initialURL)
        } else if let savedSource, sources.contains(savedSource) {
            source = savedSource
        }
    }

    // MARK: Sources and accounts

    /// The sources shown: GitHub.com, GitHub Enterprise once an Enterprise
    /// account exists (signed in, or signed out but still listed), and URL.
    var sources: [CloneSource] {
        let hasEnterprise = (app.accounts.accounts + app.accounts.invalidatedAccounts).contains { !isDotCom($0.endpoint) }
        return hasEnterprise ? CloneSource.allCases : [.gitHub, .url]
    }

    /// The signed-in accounts of a source.
    func accounts(for source: CloneSource) -> [Account] {
        switch source {
        case .gitHub: app.accounts.accounts.filter { isDotCom($0.endpoint) }
        case .enterprise: app.accounts.accounts.filter { !isDotCom($0.endpoint) }
        case .url: []
        }
    }

    /// The account the source lists: the chosen one, else the first.
    func account(for source: CloneSource) -> Account? {
        let accounts = accounts(for: source)
        if let key = fields[source]?.account, let chosen = accounts.first(where: { AccountKey($0) == key }) {
            return chosen
        }
        return accounts.first
    }

    /// The server a source's call to action signs in to: nil for GitHub.com,
    /// or the Enterprise server of a signed-out account.
    func signInEndpoint(for source: CloneSource) -> String? {
        switch source {
        case .gitHub, .url: nil
        case .enterprise: app.accounts.invalidatedAccounts.first { !isDotCom($0.endpoint) }?.endpoint
        }
    }

    func chooseAccount(_ account: Account) {
        update(source) { fields in
            fields.account = AccountKey(account)
            fields.selection = nil
        }
        setURL("")
    }

    // MARK: Fields

    var current: Fields {
        fields[source] ?? Fields(path: initialPath)
    }

    /// Whether the sheet shows the local path: always for URL; for GitHub,
    /// only with an account (the call to action shows instead).
    var showsLocalPath: Bool {
        source == .url || account(for: source) != nil
    }

    /// Sets the current source's URL; the path's last folder follows the
    /// repository's name.
    func setURL(_ url: String) {
        update(source) { fields in
            fields.path = clonePath(fields.path, afterURLChangeFrom: fields.url, to: url)
            fields.url = url
            fields.problem = nil
        }
    }

    func setPath(_ path: String) {
        update(source) { fields in
            fields.path = path
            fields.problem = nil
        }
    }

    func setFilter(_ filter: String) {
        update(source) { $0.filter = filter }
    }

    /// Selects a repository in the list: its clone URL is what's cloned.
    func select(_ id: CloneableRepositoryListItem.ID?, url: String?) {
        update(source) { $0.selection = id }
        setURL(url ?? "")
    }

    /// Whether Clone can be pressed: a URL, a path, nothing being resolved,
    /// and no problem.
    var canClone: Bool {
        let fields = current
        return !JSCompat.trim(fields.url).isEmpty && !fields.path.isEmpty && !isResolving && fields.problem == nil
    }

    // MARK: Checks and cloning

    /// Checks the current path: nothing to say about the starting folder
    /// until a URL is entered.
    func validatePath() async {
        let source = source
        let fields = current
        if JSCompat.strictEquals(fields.path, initialPath), fields.url.isEmpty {
            update(source) { $0.problem = nil }
            return
        }
        let problem = await validateClonePath(fields.path)
        // A check that finished after the path changed is stale.
        guard self.fields[source]?.path == fields.path else {
            return
        }
        update(source) { $0.problem = problem?.message }
    }

    /// Checks the path again each time Espalier becomes active while the
    /// sheet shows: the folder may have been emptied or filled in the Finder
    /// meanwhile. Runs until the calling task is cancelled.
    func validateOnActivation() async {
        let app = app
        await Observing.eachActivation({ app.isActive }) {
            await validatePath()
        }
    }

    /// Checks the path again and resolves what to clone. Nil when there's a
    /// problem, which the sheet shows.
    func prepareClone() async -> CloneRequest? {
        guard canClone else {
            return nil
        }
        let source = source
        let fields = current
        isResolving = true
        defer { isResolving = false }

        if let problem = await validateClonePath(fields.path) {
            update(source) { $0.problem = problem.message }
            return nil
        }
        do throws(OperationError) {
            let info = try await app.clones.resolveCloneInfo(fields.url)
            return CloneRequest(url: info.url, path: fields.path, options: CloneOptions(defaultBranch: info.defaultBranch))
        } catch {
            update(source) { $0.problem = error.message }
            return nil
        }
    }

    private func update(_ source: CloneSource, _ change: (inout Fields) -> Void) {
        var value = fields[source] ?? Fields(path: initialPath)
        change(&value)
        if value != fields[source] {
            fields[source] = value
        }
    }
}

/// The Clone sheet.
struct CloneSheet: View {
    static let sheetID = "repository.clone"
    /// The source the sheet was last on (UI state).
    static let sourceDefaultsKey = "espalier.clone.source"

    @State var model: CloneSheetModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    var body: some View {
        CloneForm(model: model, cancel: { dismiss() }, clone: clone)
            .task(id: ValidationKey(source: model.source, path: model.current.path, url: model.current.url)) {
                await model.validatePath()
            }
            .task {
                await model.validateOnActivation()
            }
    }

    private struct ValidationKey: Hashable {
        let source: CloneSource
        let path: String
        let url: String
    }

    private func clone() {
        let model = model
        let context = context
        Task {
            guard let request = await model.prepareClone() else {
                return
            }
            dismiss()
            if let external = model.externalRequest {
                await RepositoryActions.clone(request, in: context) { id in
                    await ExternalEventsBridge.continueAfterClone(external, in: id, context: context)
                }
            } else {
                await RepositoryActions.clone(request, in: context)
            }
        }
    }

    /// Shows the sheet: on URL with `initialURL`, else on the source last
    /// used.
    static func present(initialURL: String? = nil, externalRequest: ExternalCloneRequest? = nil, in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
        let defaults = context.uiDefaults
        let saved = defaults.string(forKey: sourceDefaultsKey).flatMap(CloneSource.init(rawValue:))
        let model = CloneSheetModel(app: context.app, initialURL: initialURL, externalRequest: externalRequest, savedSource: saved)
        model.onSourceChange = { source in
            defaults.set(source.rawValue, forKey: sourceDefaultsKey)
        }
        context.modals.presentSheet(id: sheetID) {
            CloneSheet(model: model)
        }
    }
}

/// The Clone sheet's form.
struct CloneForm: View {
    @Bindable var model: CloneSheetModel
    var cancel: () -> Void = {}
    var clone: () -> Void = {}

    var body: some View {
        SheetScaffold("Clone a Repository") {
            CapsuleSegmentedControl(
                "Source",
                selection: $model.source,
                segments: model.sources.map { CapsuleSegment($0.title, value: $0) }
            )

            // The source's content and the local path under it, in an area
            // of one height whichever source shows, so switching sources
            // never resizes the sheet: the content crossfades (0.15 s).
            VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
                sourceContent
                if model.showsLocalPath {
                    VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                        FolderField(label: "Local Path", path: Binding(get: { model.current.path }, set: { model.setPath($0) })) {
                            FolderChooser.chooseCloneDestination(model.current.path) { path in
                                model.setPath(path)
                            }
                        }
                        if let problem = model.current.problem {
                            SheetMessage(problem, kind: .error)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(model.source)
            .transition(.opacity)
            .frame(height: Metrics.Sheet.cloneSourceHeight)
            .motion(Motion.leave, value: model.source)
        } buttons: {
            SheetButtons(
                "Clone",
                isConfirmDisabled: !model.canClone || !model.showsLocalPath,
                isWorking: model.isResolving,
                cancel: cancel,
                confirm: clone
            )
        }
    }

    @ViewBuilder
    private var sourceContent: some View {
        switch model.source {
        case .gitHub, .enterprise:
            if let account = model.account(for: model.source) {
                let accounts = model.accounts(for: model.source)
                if accounts.count > 1 {
                    Picker("Account", selection: Binding(
                        get: { AccountKey(account) },
                        set: { key in
                            if let chosen = accounts.first(where: { AccountKey($0) == key }) {
                                model.chooseAccount(chosen)
                            }
                        }
                    )) {
                        ForEach(accounts, id: \.self) { account in
                            Text("@\(account.login) – \(account.friendlyEndpoint)").tag(AccountKey(account))
                        }
                    }
                }
                AccountRepositoryList(
                    account: account,
                    filter: Binding(get: { model.current.filter }, set: { model.setFilter($0) }),
                    selection: Binding(
                        get: { model.current.selection },
                        set: { id in
                            let url = CloneableListContent(
                                account: account,
                                repositories: model.app.accounts.apiRepositories.repositories(for: account),
                                filter: model.current.filter
                            ).item(id)?.url
                            model.select(id, url: url)
                        }
                    ),
                    activate: { _ in
                        if model.canClone {
                            clone()
                        }
                    }
                )
                .frame(maxHeight: .infinity)
            } else {
                RepositorySignInPrompt(isEnterprise: model.source == .enterprise, endpoint: model.signInEndpoint(for: model.source))
                    .frame(maxHeight: .infinity)
            }
        case .url:
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                Text("Repository URL or GitHub username and repository (\(Text("hubot/cool-repo").font(Typography.sha)))")
                    .font(Typography.fieldLabel)
                    .foregroundStyle(.text2)
                TextField("Repository URL", text: Binding(get: { model.current.url }, set: { model.setURL($0) }), prompt: Text("URL or username/repository"))
                    .textFieldStyle(.capsule)
                    .labelsHidden()
            }
        }
    }
}

extension Metrics.Sheet {
    /// The Clone sheet's area under its sources: a repository list 240
    /// high and the local path under it. Every source shows in it.
    public static let cloneSourceHeight: CGFloat = 284
}
