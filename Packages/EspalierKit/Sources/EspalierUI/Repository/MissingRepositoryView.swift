// The Missing and Unsafe views: Locate… (`relocateRepository`), Clone Again
// when the repository has a clone URL (`cloneAgain`), Remove, and "Check
// again."; for a repository another user owns, Trust Repository
// (`trustRepositoryDirectory`) and Remove.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the Missing or Unsafe view shows.
nonisolated struct MissingRepositoryContent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// The folder is gone.
        case missing(path: String, canCloneAgain: Bool)
        /// Git refuses to work in it: another user owns it.
        case unsafe(path: String)
    }

    var name: String
    var kind: Kind

    var title: String {
        switch kind {
        case .missing: "Can't find \u{201C}\(name)\u{201D}"
        case .unsafe: "\(name) is potentially unsafe"
        }
    }

    /// The link that checks again ("Check again.").
    static let checkAgainURL = URL(string: "espalier-action:check-again")!

    /// The description, with the "Check again." link for a missing one.
    var description: AttributedString {
        switch kind {
        case .missing(let path, _):
            var text = AttributedString("It was last seen at \(path). ")
            var link = AttributedString("Check again.")
            link.link = Self.checkAgainURL
            text.append(link)
            return text
        case .unsafe(let path):
            return AttributedString(
                "The Git repository at \(path) appears to belong to another user on this Mac. A repository you don't trust can run files in it automatically.\n\nIf you trust its owner, add an exception for this folder to continue."
            )
        }
    }
}

/// The view's look, value-driven.
struct MissingRepositoryForm: View {
    let content: MissingRepositoryContent
    var isWorking = false
    var locate: () -> Void = {}
    var cloneAgain: () -> Void = {}
    var trust: () -> Void = {}
    var remove: () -> Void = {}
    var checkAgain: () -> Void = {}
    @Environment(\.motion) private var motion

    /// The symbol: a folder with a question mark, or a shield.
    private var systemImage: String {
        switch content.kind {
        case .missing: "questionmark.folder"
        case .unsafe: "exclamationmark.shield"
        }
    }

    var body: some View {
        CenteredMessage(
            content.title,
            systemImage: systemImage,
            attributedDescription: content.description,
            tint: Color(espalier: Palette.warningMark),
            isLarge: true
        ) {
            HStack(spacing: Metrics.insetSmall) {
                switch content.kind {
                case .missing(_, let canCloneAgain):
                    Button("Remove", action: remove)
                        .buttonStyle(.quiet)
                    if canCloneAgain {
                        Button("Clone Again", action: cloneAgain)
                            .buttonStyle(.quiet)
                    }
                    Button("Locate…", action: locate)
                        .buttonStyle(.prominent)
                case .unsafe:
                    if isWorking {
                        // Fades in and out over 0.15 s on its own, so the
                        // button it disables changes at once.
                        ArcProgress(.small)
                            .transition(motion.animates ? AnyTransition.opacity.animation(Motion.animation(Motion.leave)) : .identity)
                    }
                    Button("Remove", action: remove)
                        .buttonStyle(.quiet)
                    Button("Trust Repository", action: trust)
                        .buttonStyle(.prominent)
                        .disabled(isWorking)
                }
            }
            .fixedSize()
        }
        .environment(\.openURL, OpenURLAction { url in
            if url == MissingRepositoryContent.checkAgainURL {
                checkAgain()
                return .handled
            }
            return .systemAction
        })
        .fillingSpace()
    }
}

/// A repository whose folder is gone, or that another user owns.
public struct MissingRepositoryView: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @State private var isWorking = false

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        MissingRepositoryForm(
            content: Self.content(for: repository),
            isWorking: isWorking,
            locate: locate,
            cloneAgain: cloneAgain,
            trust: trust,
            remove: remove,
            checkAgain: checkAgain
        )
    }

    static func content(for repository: RepositoryModel) -> MissingRepositoryContent {
        let record = repository.record
        if case .unsafe(let path) = repository.availability {
            return MissingRepositoryContent(name: record.displayName, kind: .unsafe(path: path))
        }
        let canCloneAgain = !(record.gitHubRepository?.cloneURL ?? "").isEmpty
        return MissingRepositoryContent(name: record.displayName, kind: .missing(path: record.path, canCloneAgain: canCloneAgain))
    }

    private func checkAgain() {
        let app = context.app
        let id = repository.id
        Task { await app.checkRepositoryAgain(id) }
    }

    /// Locate…: picks the repository's new folder (`relocateRepository`).
    private func locate() {
        let app = context.app
        let presenter = context.presenter
        let id = repository.id
        FolderChooser.chooseFolder(startingAt: nil, prompt: "Locate") { path in
            Task {
                await presenter.perform { _ throws(OperationError) in
                    try await app.relocateRepository(id, to: path)
                }
            }
        }
    }

    private func cloneAgain() {
        let clones = context.app.clones
        let presenter = context.presenter
        let id = repository.id
        Task {
            await presenter.perform { _ throws(OperationError) in
                try await clones.cloneAgain(id)
            }
        }
    }

    private func trust() {
        let app = context.app
        let presenter = context.presenter
        let id = repository.id
        isWorking = true
        Task {
            await presenter.perform { _ throws(OperationError) in
                try await app.trustRepositoryDirectory(id)
            }
            isWorking = false
        }
    }

    private func remove() {
        let context = context
        let id = repository.id
        Task { await RepositoryActions.remove(id, in: context) }
    }
}
