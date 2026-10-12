// What the detail area shows for the window's state and place. Each place
// routes to its feature's screen.

import EspalierCore
import GitKit
import SwiftUI

/// What the detail area shows.
nonisolated public enum DetailDestination: Sendable, Equatable {
    /// The app model is loading: nothing for 300 ms, then a spinner.
    case launching
    /// No repositories: Get Started.
    case getStarted
    /// Repositories exist, none is selected.
    case noRepositorySelected
    /// A repository being cloned.
    case cloning(CloneID)
    /// The selected repository's folder is gone.
    case missing(RepositoryID)
    /// Git refuses to work in the selected repository (another owner).
    case unsafe(RepositoryID, path: String)
    /// Changes.
    case changes(RepositoryID)
    /// History, a branch (the current one, or Compare), or a tag.
    case history(RepositoryID, SidebarPlace)
    case pullRequest(RepositoryID, number: Int)
    case stash(RepositoryID, branch: String)
}

extension DetailDestination {
    /// The destination for the app's state and the window's place.
    @MainActor
    public static func make(app: AppModel, place: SidebarPlace?) -> DetailDestination {
        guard app.loadState == .ready else {
            return .launching
        }
        switch app.selection {
        case nil:
            return app.repositories.isEmpty ? .getStarted : .noRepositorySelected
        case .clone(let id)?:
            return .cloning(id)
        case .repository(let id)?:
            guard let repository = app.repository(id) else {
                return app.repositories.isEmpty ? .getStarted : .noRepositorySelected
            }
            if repository.record.isMissing {
                return .missing(id)
            }
            switch repository.availability {
            case .missing: return .missing(id)
            case .unsafe(let path): return .unsafe(id, path: path)
            case .unknown, .available: break
            }
            switch place ?? .changes {
            case .changes: return .changes(id)
            case .history: return .history(id, .history)
            case .branch(let ref): return .history(id, .branch(ref: ref))
            case .tag(let name): return .history(id, .tag(name: name))
            case .pullRequest(let number): return .pullRequest(id, number: number)
            case .stash(let branch): return .stash(id, branch: branch)
            }
        }
    }
}

/// The detail area: the place's screen, or the window-level state.
struct DetailRouter: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        let app = context.app
        // A place's panes are its split's cards in the floating layout; the
        // other destinations are one card.
        switch DetailDestination.make(app: app, place: context.state.place) {
        case .launching:
            DelayedProgressView()
                .paneCard()
        case .getStarted:
            GetStartedView()
                .paneCard()
        case .noRepositorySelected:
            NoRepositorySelectedView()
                .paneCard()
        case .cloning(let id):
            Group {
                if let clone = app.clones.clones.first(where: { $0.id == id }) {
                    CloningRepositoryView(clone: clone)
                } else {
                    DelayedProgressView()
                }
            }
            .paneCard()
        case .missing(let id), .unsafe(let id, _):
            if let repository = app.repository(id) {
                MissingRepositoryView(repository: repository)
                    .paneCard()
            }
        case .changes(let id):
            if let repository = app.repository(id) {
                ChangesScreen(repository: repository)
            }
        case .history(let id, let place):
            if let repository = app.repository(id) {
                HistoryScreen(repository: repository, place: place)
            }
        case .pullRequest(let id, let number):
            if let repository = app.repository(id) {
                PullRequestScreen(repository: repository, number: number)
            }
        case .stash(let id, let branch):
            if let repository = app.repository(id) {
                StashScreen(repository: repository, branch: branch)
            }
        }
    }
}

/// "No Repository Selected", with Choose a Repository… (⌘T).
struct NoRepositorySelectedView: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        CenteredMessage("No Repository Selected", systemImage: "folder", isLarge: true) {
            HStack(spacing: Metrics.insetSmall) {
                Button("Choose a Repository…") {
                    context.actions.perform(.switchRepository)
                }
                .buttonStyle(.quiet)
                if let shortcut = ActionKind.switchRepository.shortcut?.symbols {
                    KeyCap(shortcut)
                }
            }
        }
        .fillingSpace()
    }
}
