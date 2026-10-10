// Ported from desktop/app/src/ui/diff/submodule-diff.tsx
//
// A submodule's change: the repository it's based on, the commits it moved
// between (with buttons that copy the full SHAs), its own uncommitted
// changes, and an action that opens it in Espalier.

import AppKit
import GitHubKit
import GitKit
import SwiftUI

/// What the submodule view shows.
nonisolated struct SubmoduleDiffContent: Sendable, Equatable {
    var diff: SubmoduleDiff
    /// A historical diff ("was added") rather than a working directory one
    /// ("has been added", which can be committed).
    var readOnly: Bool

    /// How the submodule's commit changed.
    enum CommitChange: Equatable {
        case changed(from: String, to: String)
        case added(at: String)
        case removed(at: String)
    }

    /// How the submodule's commit changed, or nil when it didn't.
    var commitChange: CommitChange? {
        switch (diff.oldSHA, diff.newSHA) {
        case (let oldSHA?, let newSHA?): .changed(from: oldSHA, to: newSHA)
        case (nil, let newSHA?): .added(at: newSHA)
        case (let oldSHA?, nil): .removed(at: oldSHA)
        case (nil, nil): nil
        }
    }
}

/// A submodule's change.
struct SubmoduleDiffView: View {
    let content: SubmoduleDiffContent
    /// Opens the submodule as a repository; nil when it can't be (it has no
    /// URL, as in an old commit of a submodule since deleted).
    let openSubmodule: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                HStack(spacing: Metrics.insetMedium) {
                    IconCircle("shippingbox", size: 32)
                        .accessibilityHidden(true)
                    Text("Submodule changes")
                        .font(Typography.commitSummary)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.bottom, Metrics.grid)
                if let info = repositoryInfo {
                    item(systemImage: "info.circle") {
                        info
                    }
                }
                commitChangeInfo
                if let changes = changesInfo {
                    item(systemImage: "doc.badge.ellipsis") {
                        Text(changes)
                    }
                }
                if let openSubmodule, content.diff.url != nil {
                    openAction(openSubmodule)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(Metrics.insetLarge)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Items

    private func item(systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Image(systemName: systemImage)
                .foregroundStyle(.text2)
                .frame(width: 18)
                .accessibilityHidden(true)
            content()
                .foregroundStyle(.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "This is a submodule based on the repository owner/name (host)."
    private var repositoryInfo: Text? {
        guard let url = content.diff.url, let identifier = parseRepositoryIdentifier(url) else {
            return nil
        }
        // An "owner/name" URL has no host: GitHub.com.
        let host = identifier.hostname ?? "github.com"
        let hostname = host == "github.com" ? "" : " (\(host))"
        let name = "\(identifier.owner)/\(identifier.name)\(hostname)"
        var link = AttributedString(name)
        link.link = URL(string: "https://\(host)/\(identifier.owner)/\(identifier.name)")
        return Text("This is a submodule based on the repository \(Text(link)).")
    }

    @ViewBuilder
    private var commitChangeInfo: some View {
        let verb = content.readOnly ? "was" : "has been"
        let suffix = content.readOnly ? "" : " This change can be committed to the parent repository."
        switch content.commitChange {
        case .changed(let oldSHA, let newSHA)?:
            item(systemImage: "plus.forwardslash.minus") {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    Text("This submodule changed its commit from \(shortenSHA(oldSHA)) to \(shortenSHA(newSHA)).\(suffix)")
                    HStack(spacing: Metrics.insetSmall) {
                        CopySHAButton(sha: oldSHA, which: "previous")
                        CopySHAButton(sha: newSHA, which: "new")
                    }
                }
            }
        case .added(let newSHA)?:
            item(systemImage: "plus.square") {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    Text("This submodule \(verb) added pointing at commit \(shortenSHA(newSHA)).\(suffix)")
                    CopySHAButton(sha: newSHA, which: nil)
                }
            }
        case .removed(let oldSHA)?:
            item(systemImage: "minus.square") {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    Text("This submodule \(verb) removed while it was pointing at commit \(shortenSHA(oldSHA)).\(suffix)")
                    CopySHAButton(sha: oldSHA, which: nil)
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// "This submodule has modified and untracked changes. …"
    private var changesInfo: String? {
        let status = content.diff.status
        guard status.untrackedChanges || status.modifiedChanges else {
            return nil
        }
        let changes = status.untrackedChanges && status.modifiedChanges
            ? "modified and untracked"
            : (status.untrackedChanges ? "untracked" : "modified")
        return "This submodule has \(changes) changes. Commit them inside the submodule before they can be part of the parent repository."
    }

    private func openAction(_ open: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Metrics.insetMedium) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                Text("Open this submodule in Espalier")
                    .font(Typography.heading)
                Text("You can open this submodule in Espalier as a normal repository to manage and commit any changes in it.")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.insetSmall)
            Button("Open Repository", action: open)
                .buttonStyle(.prominent)
        }
        .padding(Metrics.insetMedium + 2)
        .cardSurface()
        .padding(.top, Metrics.insetSmall)
    }
}

/// A short SHA's button that copies the full one.
private struct CopySHAButton: View {
    let sha: String
    /// "previous" or "new", for VoiceOver.
    let which: String?

    var body: some View {
        // After a copy, the symbol is a check for a moment (CopyButton).
        CopyButton(sha) { systemImage in
            MonoChip(shortenSHA(sha)) {
                // The copy symbol's room, whichever shows.
                ZStack {
                    Image(systemName: "doc.on.doc")
                        .hidden()
                    Image(systemName: systemImage)
                }
                .font(.system(size: 10))
                .foregroundStyle(.text3)
            }
        }
        .buttonStyle(.plain)
        .help("Copy the full SHA")
        .accessibilityLabel(which.map { "Copy the full \($0) SHA" } ?? "Copy the full SHA")
    }
}
