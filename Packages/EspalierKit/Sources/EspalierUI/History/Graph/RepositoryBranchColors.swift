// A repository's branch colors (`BranchColors`), for the sidebar's dots and
// History's graph and tags, which must agree whether or not History has
// loaded.

import AppKit
import EspalierCore
import GitKit

extension BranchColors {
    /// The last colors made, and what they were made from: every sidebar
    /// row asks, so the colors are made once per change of the branches.
    @MainActor private static var cache: (key: Key, colors: BranchColors)?

    private struct Key: Equatable {
        var branches: [String]
        var current: String?
        var defaultBranch: String?
        var remotes: [String]
        var accent: NSColor
        /// The theme, whose tones the colors are.
        var theme: ObjectIdentifier
    }

    /// The colors of `repository`'s branches.
    @MainActor
    static func of(_ repository: RepositoryModel) -> BranchColors {
        let state = repository.gitState
        let key = Key(
            branches: state.branches.all.compactMap { $0.type == .local ? $0.name : nil },
            current: state.tip.branch?.name,
            defaultBranch: state.branches.defaultBranch?.name,
            remotes: state.remotes.all.map(\.name),
            // Resolved, so a change of the accent color is a change.
            accent: Palette.accent.resolved(in: .light),
            theme: ObjectIdentifier(Theme.current)
        )
        if let cache, cache.key == key {
            return cache.colors
        }
        let colors = BranchColors(
            branches: key.branches,
            current: key.current,
            defaultBranch: key.defaultBranch,
            remoteNames: key.remotes
        )
        cache = (key, colors)
        return colors
    }
}
