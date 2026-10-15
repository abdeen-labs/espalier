// "Do you want to fork this repository?", which the shell's error host shows
// for `.insufficientPermissions`: the error's text and where the fork will
// be, Fork This Repository (forking runs in the sheet, `createFork()`), the
// failure with a link to fork on GitHub, then "How are you planning to use
// this fork?" with its two choices and what each means.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the sheet shows.
nonisolated enum CreateForkStep: Sendable, Equatable {
    /// Whether to fork, and where the fork will be ("joe/website").
    case question(message: String, forkName: String?)
    /// Forking.
    case forking(forkName: String?)
    /// Forking failed; the repository's page, to fork it there.
    case failed(message: String, repositoryURL: URL?)
    /// How the fork is used: its parent's name, its own, and the choice.
    case settings(parent: String, fork: String, target: ForkContributionTarget)
}

/// Offers to fork a repository the account can't push to.
public struct CreateForkSheet: View {
    private let error: OperationError
    @Environment(\.dismissModal) private var dismissModal
    @Environment(WindowContext.self) private var context: WindowContext?
    @State private var phase = Phase.question
    @State private var target = ForkContributionTarget.parent

    private enum Phase: Equatable {
        case question
        case forking
        case failed(String)
        case settings
    }

    public init(error: OperationError) {
        self.error = error
    }

    public var body: some View {
        CreateForkView(
            step: step,
            target: $target,
            cancel: { dismissModal() },
            fork: fork,
            open: { url in
                context?.app.integrations.openInBrowser(url)
            },
            finish: finish
        )
    }

    private var repository: RepositoryModel? {
        error.repositoryID.flatMap { context?.app.repository($0) }
    }

    /// Where the fork will be: "<login>/<name>".
    private var forkName: String? {
        guard let repository, let gitHubRepository = repository.record.gitHubRepository,
              let account = context?.app.accounts.account(for: repository.record)
        else {
            return nil
        }
        return "\(account.login)/\(gitHubRepository.name)"
    }

    private var step: CreateForkStep {
        switch phase {
        case .question:
            return .question(message: error.message, forkName: forkName)
        case .forking:
            return .forking(forkName: forkName)
        case .failed(let message):
            let url = repository?.record.gitHubRepository?.htmlURL.flatMap(URL.init(string:))
            return .failed(message: message, repositoryURL: url)
        case .settings:
            let gitHubRepository = repository?.record.gitHubRepository
            return .settings(
                parent: gitHubRepository?.parent?.fullName ?? "",
                fork: gitHubRepository?.fullName ?? forkName ?? "",
                target: target
            )
        }
    }

    private func fork() {
        guard let repository, let context, phase == .question else {
            return
        }
        phase = .forking
        Task {
            switch await Self.fork(repository, presenter: context.presenter) {
            case .settings(let current):
                target = current
                phase = .settings
            case .done:
                dismissModal()
            case .cancelled:
                phase = .question
            case .failed(let message):
                phase = .failed(message)
            }
        }
    }

    private func finish() {
        if let id = repository?.id {
            context?.app.setForkContributionTarget(target, for: id)
        }
        dismissModal()
    }

    /// What forking led to.
    enum ForkResult: Equatable {
        /// Forked: how the fork is used comes next, starting from the
        /// repository's choice.
        case settings(ForkContributionTarget)
        /// Forked, with nothing to ask (the fork has no parent).
        case done
        /// A question on the way was cancelled; nothing changed.
        case cancelled
        /// Forking failed, with this message.
        case failed(String)
    }

    /// Forks the repository under the signed-in account (`createFork()`)
    /// through the window's presenter, which answers its questions.
    static func fork(_ repository: RepositoryModel, presenter: WindowPresenter) async -> ForkResult {
        do throws(OperationError) {
            let forked: Void? = try await presenter.performThrowing { _ throws(OperationError) in
                try await repository.sync.createFork()
            }
            guard forked != nil else {
                return .cancelled
            }
            guard repository.record.gitHubRepository?.parent != nil else {
                return .done
            }
            return .settings(getForkContributionTarget(repository.record))
        } catch {
            return .failed(error.message)
        }
    }

    /// Shows the sheet for a repository (the `.createFork` action, when the
    /// recovery runs from somewhere other than the error's own sheet).
    @MainActor
    static func present(repositoryID: RepositoryID, in context: WindowContext) {
        guard let repository = context.app.repository(repositoryID) else {
            return
        }
        let fullName = repository.record.gitHubRepository?.fullName ?? repository.record.name
        let error = OperationError(.insufficientPermissions(repositoryFullName: fullName), operation: .push, repositoryID: repositoryID)
        context.modals.presentSheet(id: ErrorHost.sheetID) {
            CreateForkSheet(error: error)
        }
    }
}

/// The sheet's content for a step.
struct CreateForkView: View {
    let step: CreateForkStep
    @Binding var target: ForkContributionTarget
    let cancel: () -> Void
    let fork: () -> Void
    let open: (URL) -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            switch step {
            case .question(let message, let forkName):
                title(stepTitle)
                Text(message)
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let forkName {
                    Text("Do you want to create a fork of this repository at **\(forkName)** to continue?")
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons {
                    Button("Cancel", role: .cancel, action: cancel)
                        .buttonStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                    Button("Fork This Repository", action: fork)
                        .buttonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                }

            case .forking(let forkName):
                title(stepTitle)
                HStack(spacing: Metrics.insetSmall) {
                    ArcProgress(.small)
                    Text(forkName.map { "Creating your fork \($0)…" } ?? "Creating your fork…")
                        .foregroundStyle(.text2)
                }
                buttons {
                    Button("Cancel", role: .cancel, action: cancel)
                        .buttonStyle(.secondary)
                        .disabled(true)
                    Button("Fork This Repository", action: fork)
                        .buttonStyle(.prominent)
                        .disabled(true)
                }

            case .failed(let message, let repositoryURL):
                title(stepTitle)
                SignInInlineError(message: message)
                if let repositoryURL {
                    Button("Create the Fork on GitHub") {
                        open(repositoryURL)
                    }
                    .buttonStyle(.textLink)
                }
                buttons {
                    SheetDismissButton("Close", action: cancel)
                }

            case .settings(let parent, let fork, let selected):
                title(stepTitle)
                Text("This repository is a fork. How do you plan to use it?")
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ForkTargetPicker(
                    content: ForkSettingsContent(parent: parent, fork: fork, target: selected),
                    target: $target,
                    parentTitle: "To contribute to the parent project",
                    label: "This repository is a fork. How do you plan to use it?"
                )
                ForkTargetDescription(repository: selected == .parent ? parent : fork)
                buttons {
                    Button("Continue", action: finish)
                        .buttonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Metrics.Sheet.padding)
        .frame(width: Metrics.Sheet.standardWidth, alignment: .leading)
        .background(Color(espalier: Palette.background))
        .modalTitle(stepTitle)
    }

    /// The step's title, which also names the sheet for VoiceOver.
    private var stepTitle: String {
        switch step {
        case .question, .forking, .failed: "Do you want to fork this repository?"
        case .settings: "How are you planning to use this fork?"
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Typography.sheetTitle)
            .foregroundStyle(.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            Spacer()
            content()
        }
        .padding(.top, Metrics.grid)
    }
}

/// What a fork's choice means. Repository Settings' Fork Behavior shows it
/// too.
struct ForkTargetDescription: View {
    let repository: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.bulletSpacing) {
                    Text("•")
                    Text(lines[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Typography.secondary)
        .foregroundStyle(.text2)
    }

    private var lines: [LocalizedStringKey] {
        [
            "Pull requests targeting **\(repository)** will be shown in the pull request list.",
            "Issues will be created in **\(repository)**.",
            "\"View on GitHub\" will open **\(repository)** in the browser.",
            "New branches will be based on **\(repository)**'s default branch.",
            "Autocompletion of users and issues will be based on **\(repository)**.",
        ]
    }
}
