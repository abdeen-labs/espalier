// Get Started, the window with no repositories, modelled on Xcode's welcome
// window: a heading, three actions, the account's repositories on the right
// when signed in (with the account picker for two or more accounts), and
// "Clone <owner/name>", which opens Clone on URL with the repository.
// Folders dropped on the window add repositories (MainWindow).

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// Get Started.
public struct GetStartedView: View {
    @Environment(WindowContext.self) private var context
    @State private var accountKey: AccountKey?
    @State private var filter = ""
    @State private var selection: CloneableRepositoryListItem.ID?

    public init() {}

    public var body: some View {
        let accounts = context.app.accounts.accounts
        let account = accounts.first { AccountKey($0) == accountKey } ?? accounts.first
        HStack(alignment: .top, spacing: Metrics.insetLarge * 2) {
            GetStartedActions(
                clone: { context.actions.perform(.cloneRepository(url: nil)) },
                create: { context.actions.perform(.newRepository(path: nil)) },
                add: { context.actions.perform(.addLocalRepository) }
            )
            .frame(maxWidth: Metrics.GetStarted.actionsWidth, alignment: .leading)

            if let account {
                VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                    SectionLabel("Your Repositories")
                        .padding(.leading, Metrics.grid)
                    if accounts.count > 1 {
                        Picker("Account", selection: Binding(
                            get: { AccountKey(account) },
                            set: { key in
                                accountKey = key
                                selection = nil
                            }
                        )) {
                            ForEach(accounts, id: \.self) { account in
                                Text("@\(account.login) – \(account.friendlyEndpoint)").tag(AccountKey(account))
                            }
                        }
                    }
                    AccountRepositoryList(account: account, filter: $filter, selection: $selection) { item in
                        clone(item.url)
                    }
                    .frame(minHeight: 240)
                    HStack {
                        Spacer()
                        let selected = listContent(for: account).item(selection)
                        Button(selected.map { "Clone \($0.text.first ?? $0.name)" } ?? "Clone") {
                            if let selected {
                                clone(selected.url)
                            }
                        }
                        .buttonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected == nil)
                    }
                }
                .frame(maxWidth: Metrics.GetStarted.listWidth)
            }
        }
        .padding(Metrics.insetLarge * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listContent(for account: Account) -> CloneableListContent {
        CloneableListContent(account: account, repositories: context.app.accounts.apiRepositories.repositories(for: account), filter: filter)
    }

    /// "Clone <owner/name>": Clone on URL with the repository.
    private func clone(_ url: String) {
        CloneSheet.present(initialURL: url, in: context)
    }
}

/// Get Started's left column: the heading, the three actions with their
/// keys, and the hint about dropping folders.
struct GetStartedActions: View {
    var clone: () -> Void = {}
    var create: () -> Void = {}
    var add: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetLarge + Metrics.grid) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                Text("Let's get started!")
                    .font(Typography.welcomeTitle)
                    .foregroundStyle(.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Add a repository to Espalier to start collaborating")
                    .font(Typography.row)
                    .foregroundStyle(.text2)
            }
            ActionList([
                ActionListItem(
                    systemImage: "arrow.down.circle",
                    title: "Clone a Repository from the Internet…",
                    keyCap: ActionKind.cloneRepository.shortcut?.symbols,
                    action: clone
                ),
                ActionListItem(
                    systemImage: "plus",
                    title: "Create a New Repository on Your Mac…",
                    keyCap: ActionKind.newRepository.shortcut?.symbols,
                    action: create
                ),
                ActionListItem(
                    systemImage: "folder",
                    title: "Add an Existing Repository from Your Mac…",
                    keyCap: ActionKind.addLocalRepository.shortcut?.symbols,
                    action: add
                ),
            ])
            Label("You can also drag a repository folder here.", systemImage: "arrow.down.doc")
                .font(Typography.meta)
                .foregroundStyle(.text3)
        }
    }
}
