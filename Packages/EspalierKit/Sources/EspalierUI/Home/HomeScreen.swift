// Home: the window's full detail area while it shows Home in place of a
// repository (`WindowState.isShowingHome`). It reads `AppModel.board`,
// builds Home's content, and runs what its controls ask: a card's next
// step (opening the work where the step is, or pushing and cleaning up in
// place), Fetch All, and Push All, each told the way the app tells
// outcomes.

import EspalierCore
import GitHubKit
import GitKit
import Observation
import SwiftUI

/// What Home keeps in its window: the focused card, and what runs.
@MainActor @Observable
final class HomeModel {
    /// The card the user last moved the focus to.
    var focus: WorktreeKey?
    var running = HomeRunning()
    /// The pieces of work whose Push or Clean Up was asked for and hasn't
    /// ended, asking or running.
    @ObservationIgnored var startedSteps: Set<WorktreeKey> = []
    /// Whether Push All was asked for and hasn't ended, asking or running.
    @ObservationIgnored var isPushAllStarted = false
    @ObservationIgnored var fetchAll: Task<Void, Never>?
}

extension WindowContext {
    /// What Home keeps in this window.
    var homeModel: HomeModel {
        state.featureState(HomeModel.self) { HomeModel() }
    }

    /// Whether the window shows Home.
    var isOnHome: Bool {
        DetailDestination.make(app: app, isShowingHome: state.isShowingHome, place: state.place) == .home
    }
}

/// Home's screen.
struct HomeScreen: View {
    @Environment(WindowContext.self) private var context
    /// Whether the Quiet line is open, remembered.
    @AppStorage("home.quiet-open") private var isQuietOpen = false

    var body: some View {
        let model = context.homeModel
        HomeView(content: content(model), isQuietOpen: $isQuietOpen, actions: actions(model))
    }

    /// The content of the board now.
    private func content(_ model: HomeModel) -> HomeContent {
        let app = context.app
        let board = app.board
        return HomeContent.make(board: board, running: model.running, focus: model.focus, isScanningFolders: app.isScanningFolders) { piece, branch in
            guard let repository = app.repository(piece.record.id) else {
                return Palette.accent
            }
            return BranchColors.of(repository).color(of: (name: branch, isRemote: false))
        }
    }

    private func actions(_ model: HomeModel) -> HomeViewActions {
        let context = context
        return HomeViewActions(
            takeStep: { card in
                model.focus = card.id
                Task { await HomeSteps.take(card, model: model, in: context) }
            },
            open: { key in
                Task { await HomeActions.open(key, place: nil, in: context) }
            },
            openRepository: { id in
                RepositoryActions.switchTo(.repository(id), in: context)
            },
            focus: { key in
                model.focus = key
            },
            fetchAll: {
                HomeSteps.fetchAll(model: model, in: context)
            },
            stopFetchAll: {
                model.fetchAll?.cancel()
            },
            pushAll: {
                Task { await HomeSteps.pushAll(model: model, in: context) }
            },
            turnOnStatus: {
                context.app.preferences.repositoryIndicatorsEnabled = true
            },
            menu: { key in
                HomeContextMenu.content(key, context: context)
            }
        )
    }
}

/// What Home's buttons run.
@MainActor
enum HomeSteps {
    /// Takes `card`'s next step: opens the work where the step is and goes
    /// on there, or pushes or cleans up in place.
    static func take(_ card: HomeCard, model: HomeModel, in context: WindowContext) async {
        guard let route = card.route, !model.startedSteps.contains(card.id) else {
            return
        }
        let app = context.app
        let key = card.id
        let setRunning: @MainActor (Bool) -> Void = { isRunning in
            if isRunning {
                model.running.pieces.insert(key)
            } else {
                model.running.pieces.remove(key)
            }
        }
        switch route {
        case .open(let place, let then):
            await HomeActions.open(key, place: place, in: context)
            // It stays on Home when the work couldn't be opened.
            guard !context.state.isShowingHome, let then else {
                return
            }
            follow(then, in: context)
        case .push:
            model.startedSteps.insert(key)
            let outcome = await perform(asksFirst: false, in: context, setRunning: setRunning) { _ throws(OperationError) in
                try await app.pushWork(key)
            }
            model.startedSteps.remove(key)
            ShellActions.finish(outcome, in: context)
        case .cleanUp(let request):
            model.startedSteps.insert(key)
            await perform(asksFirst: true, in: context, setRunning: setRunning) { answers throws(OperationError) in
                try await app.cleanUp(request, confirmed: answers.confirmed)
            }
            model.startedSteps.remove(key)
        }
    }

    /// Runs `intent` as `WindowPresenter.perform` does, showing it as
    /// running only while a run the user agreed to goes: `setRunning(true)`
    /// as such a run starts, `setRunning(false)` as it ends. While the
    /// presenter asks, nothing runs; after a Cancel, nothing does again.
    ///
    /// - Parameter asksFirst: The intent always asks before it changes
    ///   anything (Push All, Clean Up): only a run with a confirmation the
    ///   user gave counts, not the first, which only reads what to ask.
    ///   Otherwise the click was the agreement, and every run counts.
    @discardableResult
    static func perform<T: Sendable>(
        asksFirst: Bool,
        in context: WindowContext,
        setRunning: @escaping @MainActor (Bool) -> Void,
        _ intent: @escaping @MainActor (IntentAnswers) async throws(OperationError) -> T
    ) async -> T? {
        await context.presenter.perform { answers throws(OperationError) in
            let isAgreed = !asksFirst || !answers.confirmed.isEmpty
            if isAgreed {
                setRunning(true)
            }
            defer {
                if isAgreed {
                    setRunning(false)
                }
            }
            return try await intent(answers)
        }
    }

    /// What follows opening a piece of work, in its repository.
    static func follow(_ followUp: HomeFollowUp, in context: WindowContext) {
        guard let repository = context.repository else {
            return
        }
        switch followUp {
        case .allWork:
            repository.allWork.choose(.allWork)
        case .checks(let number):
            // The toolbar's chip shows the checks of the branch's pull
            // request; without it, the pull request's place does.
            if repository.gitHub.currentPullRequest?.pullRequestNumber == number {
                context.state.isChecksPopoverPresented = true
            } else {
                context.select(.pullRequest(number: number))
            }
        case .pull:
            context.actions.perform(.pull)
        case .createPullRequest:
            context.actions.perform(.createPullRequest)
        }
    }

    /// Fetches every repository, its progress on Home, until it's done or
    /// stopped; then says what happened.
    static func fetchAll(model: HomeModel, in context: WindowContext) {
        guard model.fetchAll == nil else {
            return
        }
        let app = context.app
        model.running.batch.isFetching = true
        model.running.batch.fetch = nil
        model.fetchAll = Task {
            let result = await app.fetchAll { progress in
                model.running.batch.fetch = progress
            }
            model.running.batch.isFetching = false
            model.running.batch.fetch = nil
            model.fetchAll = nil
            report(HomeBatchReport.fetchAll(result, name: { app.record($0)?.displayName ?? "" }, format: app.preferences.numberFormat), in: context)
        }
    }

    /// Pushes every branch Push All would, after its confirmation; then says
    /// what happened.
    static func pushAll(model: HomeModel, in context: WindowContext) async {
        guard !model.isPushAllStarted else {
            return
        }
        let app = context.app
        let keys = app.board.pushAll.map(\.id)
        guard !keys.isEmpty else {
            return
        }
        model.isPushAllStarted = true
        let result = await perform(asksFirst: true, in: context, setRunning: { model.running.batch.isPushingAll = $0 }) { answers throws(OperationError) in
            try await app.pushAll(keys, confirmed: answers.confirmed)
        }
        model.isPushAllStarted = false
        if let result {
            report(HomeBatchReport.pushAll(result, name: { app.record($0.repositoryID)?.displayName ?? "" }, format: app.preferences.numberFormat), in: context)
        }
    }

    /// Tells a batch's outcome: a toast, or an alert naming what didn't go
    /// through.
    static func report(_ report: HomeBatchReport?, in context: WindowContext) {
        switch report {
        case .toast(let message, let tone)?:
            context.presenter.show(Toast(message, systemImage: tone == .success ? "checkmark.circle.fill" : "info.circle.fill", tone: tone))
        case .alert(let title, let message)?:
            Task {
                _ = await context.modals.alert(AlertContent(title: title, message: message, buttons: [AlertContent.Button("OK", role: .primary)]))
            }
        case nil:
            break
        }
    }
}

/// A piece of work's context menu on Home: Pin or Unpin Repository, the
/// repository popover's menu for its repository, and for a linked worktree
/// the worktree's menu.
@MainActor
enum HomeContextMenu {
    @MenuBuilder
    static func content(_ key: WorktreeKey, context: WindowContext) -> MenuContent {
        let app = context.app
        let id = key.repositoryID
        let isPinned = app.worktreeActivity.pinnedRepositoryIDs.contains(id)
        MenuAction(isPinned ? "Unpin Repository" : "Pin Repository") {
            if isPinned {
                app.worktreeActivity.unpin(id)
            } else {
                app.worktreeActivity.pin(id)
            }
        }
        MenuDivider()
        RepositoryContextMenu.content(entry: .repository(id), context: context)
        if let repository = app.repository(id), let worktree = linkedWorktree(key, of: repository) {
            MenuDivider()
            WorktreeContextMenu.content(
                WorktreeRowContent(worktree, isCurrent: WorktreeKey(repositoryID: id, path: repository.record.path) == key, isMissing: repository.worktrees.isMissing(worktree)),
                of: repository,
                context: context
            )
        }
    }

    /// The linked worktree `key` is, among the repository's.
    private static func linkedWorktree(_ key: WorktreeKey, of repository: RepositoryModel) -> WorktreeEntry? {
        repository.worktrees.entries.first { entry in
            entry.type != .main && WorktreeKey(repositoryID: repository.id, path: entry.path) == key
        }
    }
}
