// Facts the state layer exposes that are neither errors nor outcomes, each
// shown once when it first appears.

import AppKit
import EspalierCore
import Foundation
import GitHubKit
import GitKit

/// A notice to show once.
nonisolated public struct StateNotice: Sendable, Equatable {
    /// Identifies the notice, so it's shown once.
    public var key: String
    public var alert: AlertContent

    public init(key: String, alert: AlertContent) {
        self.key = key
        self.alert = alert
    }
}

extension StateNotice {
    /// The notice for a problem with the repository list.
    public static func persistence(_ issue: PersistenceIssue) -> StateNotice {
        switch issue {
        case .repositoryListUnreadable(let movedTo):
            StateNotice(key: "persistence.unreadable", alert: AlertContent(
                title: "Espalier couldn't read its repository list.",
                message: "The file was moved to \(movedTo.path(percentEncoded: false)) and Espalier started with an empty list.",
                buttons: [AlertContent.Button("OK", role: .primary), AlertContent.Button("Show in Finder", role: .secondary)]
            ))
        case .repositoryListFromNewerVersion:
            StateNotice(key: "persistence.newerVersion", alert: AlertContent(
                title: "This repository list was saved by a newer version of Espalier.",
                message: "Changes to the list won't be saved until you update Espalier.",
                buttons: [AlertContent.Button("OK", role: .primary)]
            ))
        case .repositoryListInaccessible(let reason):
            StateNotice(key: "persistence.inaccessible", alert: AlertContent(
                title: "Espalier couldn't read its repository list.",
                message: "\(reason)\n\nChanges to the list won't be saved until Espalier can read it.",
                buttons: [AlertContent.Button("OK", role: .primary)]
            ))
        case .repositoryListSaveFailed(let reason):
            StateNotice(key: "persistence.saveFailed", alert: AlertContent(
                title: "Espalier couldn't save its repository list.",
                message: reason,
                buttons: [AlertContent.Button("OK", role: .primary)]
            ))
        }
    }

    /// The notice for a fork whose `upstream` remote points elsewhere
    /// ("Upstream Already Exists").
    public static func upstreamRemoteConflict(
        repositoryID: RepositoryID,
        repositoryName: String,
        parentName: String,
        currentURL: String,
        expectedURL: String
    ) -> StateNotice {
        StateNotice(key: "upstream.\(repositoryID.rawValue).\(currentURL)", alert: AlertContent(
            title: "Upstream Already Exists",
            message: "The repository \(repositoryName) is a fork of \(parentName), but its upstream remote points elsewhere.\n\nCurrent: \(currentURL)\nExpected: \(expectedURL)\n\nWould you like to update the remote to use the expected URL?",
            buttons: [AlertContent.Button("Update", role: .destructive), AlertContent.Button("Ignore", role: .cancel)]
        ))
    }
}

/// Shows the window's state notices.
@MainActor
enum StateNoticesHost {
    /// Shows the repository list's issue, once.
    static func showPersistenceIssue(in context: WindowContext) {
        guard let issue = context.app.persistenceIssue else {
            return
        }
        let notice = StateNotice.persistence(issue)
        guard context.state.shownNotices.insert(notice.key).inserted else {
            return
        }
        Task {
            let response = await context.modals.alert(notice.alert)
            if case .repositoryListUnreadable(let movedTo) = issue, response.buttonIndex == 1 {
                NSWorkspace.shared.activateFileViewerSelecting([movedTo])
            }
            context.app.dismissPersistenceIssue()
        }
    }

    /// Shows launch's Git LFS filters failure once ("Update Existing Git LFS
    /// Filters?"): Not Now dismisses it, Update Existing Filters runs its
    /// recovery (which clears it), and Edit Global Git Config… opens the
    /// file in the editor, leaving the filters to the user.
    static func showLFSFiltersError(in context: WindowContext) {
        let integrations = context.app.integrations
        guard let error = integrations.lfsFiltersError,
              context.state.shownNotices.insert("lfs.filters").inserted,
              case .alert(let content, let recoveries) = error.presentation else {
            return
        }
        Task {
            let response = await context.modals.alert(content)
            guard recoveries.indices.contains(response.buttonIndex) else {
                integrations.dismissLFSFiltersError()
                return
            }
            let recovery = recoveries[response.buttonIndex]
            if case .updateLFSFilters = recovery {} else {
                integrations.dismissLFSFiltersError()
            }
            await context.presenter.run(recovery)
        }
    }

    /// Shows the selected repository's upstream remote conflict, once.
    static func showUpstreamRemoteConflict(in context: WindowContext) {
        guard let repository = context.app.selectedRepository,
              let conflict = repository.sync.upstreamRemoteConflict,
              let parent = repository.record.gitHubRepository?.parent else {
            return
        }
        let notice = StateNotice.upstreamRemoteConflict(
            repositoryID: repository.id,
            repositoryName: repository.record.name,
            parentName: parent.fullName,
            currentURL: conflict.existingRemote.url,
            expectedURL: parent.cloneURL ?? ""
        )
        guard context.state.shownNotices.insert(notice.key).inserted else {
            return
        }
        Task {
            let response = await context.modals.alert(notice.alert)
            if response.buttonIndex == 0 {
                await context.presenter.perform { _ throws(OperationError) in
                    try await repository.sync.updateUpstreamRemote()
                }
            } else {
                repository.sync.ignoreUpstreamRemote()
            }
        }
    }
}
