// Clone a Repository (⇧⌘O): GitHub and URL, each with its own URL, path,
// filter, selection, and problem. GitHub lists the repositories of the
// account chosen in its pop-up, which lists every signed-in account by host
// (GitHub.com's first, then each GitHub Enterprise host's) and starts on the
// account last chosen in this session, else the first; without an account it
// signs in to GitHub.com or GitHub Enterprise and chooses the new account.
// The local path follows the URL (`clonePath(_:afterURLChangeFrom:to:)`), a
// leading `~` in it is the home folder, with its checks (`validateClonePath`)
// and its warning (`clonePathWarning`). Clone takes the tab and the account
// as they are when it's pressed, resolves what to clone (`resolveCloneInfo`),
// closes the sheet, and clones, unless Cancel was pressed meanwhile; a
// repository from the GitHub list is cloned with its account only.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Where a clone comes from: a segment of the sheet.
nonisolated enum CloneSource: String, CaseIterable, Sendable, Identifiable {
    case gitHub, url

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .gitHub: "GitHub"
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
    }

    /// The account last chosen in the GitHub tab in this session.
    static var lastChosenAccount: AccountIdentity?

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
    /// The account chosen in the GitHub tab, if any.
    private(set) var chosenAccount: AccountIdentity?
    /// The account whose list the GitHub tab's selection and filter belong
    /// to.
    private(set) var listedAccount: AccountIdentity?
    /// Clone is resolving what to clone.
    private(set) var isResolving = false
    /// Cancel was pressed: a clone being prepared doesn't start.
    private(set) var isCancelled = false
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
        chosenAccount = Self.lastChosenAccount
        if let initialURL, !initialURL.isEmpty {
            source = .url
            setURL(initialURL)
        } else if let savedSource {
            source = savedSource
        }
        listedAccount = account?.identity
    }

    // MARK: Accounts

    /// The signed-in accounts, as the pop-up lists them.
    var accounts: [Account] {
        groupAccountsForPicker(app.accounts.accounts).flatMap(\.accounts)
    }

    /// The account the GitHub tab lists: the one chosen, while it's signed
    /// in, else the first.
    var account: Account? {
        let accounts = accounts
        if let chosenAccount, let chosen = accounts.first(where: { $0.identity == chosenAccount }) {
            return chosen
        }
        return accounts.first
    }

    /// Chooses the account the GitHub tab lists, for this session too: the
    /// selection and filter, another account's, go.
    func chooseAccount(_ identity: AccountIdentity) {
        chosenAccount = identity
        Self.lastChosenAccount = identity
        accountDidChange()
    }

    /// The account the GitHub tab lists changed (chosen, signed out): a
    /// repository selected from another account's list isn't cloned with
    /// this one.
    func accountDidChange() {
        let current = account?.identity
        guard current != listedAccount else {
            return
        }
        listedAccount = current
        update(.gitHub) { fields in
            fields.path = clonePath(fields.path, afterURLChangeFrom: fields.url, to: "")
            fields.url = ""
            fields.selection = nil
            fields.filter = ""
            fields.problem = nil
        }
    }

    // MARK: Fields

    var current: Fields {
        fields[source] ?? Fields(path: initialPath)
    }

    /// Whether the sheet shows the local path: always for URL; for GitHub,
    /// only with an account (the call to action shows instead).
    var showsLocalPath: Bool {
        source == .url || account != nil
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

    /// What to know about the current path that doesn't stop the clone:
    /// nothing about the starting folder until a URL is entered.
    var pathWarning: CloneDestinationWarning? {
        let fields = current
        if JSCompat.strictEquals(fields.path, initialPath), fields.url.isEmpty {
            return nil
        }
        return clonePathWarning(fields.path)
    }

    /// Whether Clone can be pressed: a URL, a path, nothing being resolved,
    /// and no problem (a warning doesn't stop it).
    var canClone: Bool {
        let fields = current
        return !JSCompat.trim(fields.url).isEmpty && !fields.path.isEmpty && !isResolving && fields.problem == nil
    }

    // MARK: Checks and cloning

    /// Checks the current path: nothing to say about an empty one, or about
    /// the starting folder until a URL is entered.
    func validatePath() async {
        let source = source
        let fields = current
        if fields.path.isEmpty || (JSCompat.strictEquals(fields.path, initialPath) && fields.url.isEmpty) {
            update(source) { $0.problem = nil }
            return
        }
        let problem = await validateClonePath(expandingTilde(fields.path))
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

    /// Checks the path again and resolves what to clone, with the tab and
    /// the account as they are now. Nil when there's a problem, which the
    /// sheet shows, and when Cancel was pressed meanwhile.
    func prepareClone() async -> CloneRequest? {
        guard canClone else {
            return nil
        }
        let source = source
        let fields = current
        // A repository from the GitHub list is cloned with the account that
        // listed it, and only with it.
        let account = source == .gitHub ? listedAccount : nil
        if source == .gitHub, account == nil || account != self.account?.identity {
            accountDidChange()
            return nil
        }
        let path = expandingTilde(fields.path)
        isResolving = true
        defer { isResolving = false }

        if let problem = await validateClonePath(path) {
            update(source) { $0.problem = problem.message }
            return nil
        }
        do throws(OperationError) {
            let info = try await app.clones.resolveCloneInfo(fields.url, account: account)
            guard !isCancelled else {
                return nil
            }
            return CloneRequest(url: info.url, path: path, options: CloneOptions(defaultBranch: info.defaultBranch), account: account)
        } catch {
            update(source) { $0.problem = error.message }
            return nil
        }
    }

    /// Cancel: a clone being prepared doesn't start.
    func cancel() {
        isCancelled = true
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
        CloneForm(model: model, cancel: cancel, clone: clone)
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

    private func cancel() {
        model.cancel()
        dismiss()
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
    @Environment(\.motion) private var motion

    var body: some View {
        SheetScaffold("Clone a Repository") {
            // The sources' tabs, centered, as a tab view's.
            CapsuleSegmentedControl(
                "Source",
                selection: $model.source,
                segments: CloneSource.allCases.map { CapsuleSegment($0.title, value: $0) }
            )
            .frame(maxWidth: .infinity)

            // The source's content and the local path under it, in an area
            // of one height whichever source shows, so switching sources
            // never resizes the sheet: the content crossfades (0.15 s).
            VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
                if model.source == .gitHub {
                    accountRepositories
                }
                if model.showsLocalPath {
                    fields
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(model.source)
            .transition(motion.animates ? .opacity : .identity)
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
        // The tab and the account can't change while Clone resolves.
        .disabled(model.isResolving)
        .onChange(of: model.account?.identity) {
            model.accountDidChange()
        }
    }

    /// The accounts' pop-up and the chosen account's repositories; without
    /// an account, the call to action.
    @ViewBuilder
    private var accountRepositories: some View {
        if let account = model.account {
            AccountPicker(accounts: model.accounts, selection: Binding(
                get: { account.identity },
                set: { identity in
                    if let identity {
                        model.chooseAccount(identity)
                    }
                }
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
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
            AccountsSignInPrompt { account in
                model.chooseAccount(account.identity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The URL (for URL) and the local path, with the problem and the
    /// path's warning under them.
    private var fields: some View {
        Form {
            // The labels in the form's column; the fields are capsules.
            if model.source == .url {
                LabeledContent("Repository URL") {
                    TextField("Repository URL", text: Binding(get: { model.current.url }, set: { model.setURL($0) }), prompt: Text("URL or username/repository").fieldPrompt())
                        .labelsHidden()
                }
            }
            FolderField(label: "Local Path", path: Binding(get: { model.current.path }, set: { model.setPath($0) })) {
                FolderChooser.chooseCloneDestination(model.current.path) { path in
                    model.setPath(path)
                }
            }
            if let problem = model.current.problem {
                FieldMessage(problem, kind: .error)
            }
            if let warning = model.pathWarning {
                FieldMessage(warning.message, kind: .warning)
            }
        }
        .formStyle(.columns)
        .textFieldStyle(.capsule)
    }
}

extension Metrics.Sheet {
    /// The Clone sheet's area under its sources: a repository list and the
    /// local path under it. Every source shows in it.
    public static let cloneSourceHeight: CGFloat = listHeight + spacing + Metrics.ControlHeight.regular
}
