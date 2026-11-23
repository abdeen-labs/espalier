// The operation capsule: an operation's progress, or its conflicts, outside
// Changes. Its conflict copy is `MultiCommitOperation.conflictsMessage`; an
// interrupted rebase's is `MultiCommitOperation.interruptedMessage`.

import EspalierCore
import GitKit
import SwiftUI

/// What the operation capsule shows.
nonisolated public enum OperationCapsuleContent: Sendable, Equatable {
    /// A merge, rebase, cherry-pick, squash, reorder, or revert running:
    /// "Rebase in progress", "Commit 2 of 5 · Wire device flow", and its
    /// progress (0 to 1) when known.
    case running(title: String, detail: String?, progress: Double?)
    /// Stopped on conflicts: the conflicts message, with View Conflicts.
    case conflicted(message: String)
    /// A rebase git was interrupted in between two commits: the state
    /// layer's copy, with View Rebase (Changes continues or aborts it).
    case interrupted(message: String)
    /// A `git am` or a bisect, which only git can finish: the state
    /// layer's note, with Open in Terminal.
    case unsupported(message: String)
}

extension OperationCapsuleContent {
    /// Which of the capsule's looks it has, without what it says: the
    /// capsule animates only when this changes.
    public enum Kind: Sendable, Equatable {
        case running, conflicted, interrupted, unsupported
    }

    public var kind: Kind {
        switch self {
        case .running: .running
        case .conflicted: .conflicted
        case .interrupted: .interrupted
        case .unsupported: .unsupported
        }
    }

    /// The capsule for a repository's state, its counts in `numberFormat`,
    /// or nil when nothing runs and nothing waits on conflicts.
    @MainActor
    public static func make(_ repository: RepositoryModel, numberFormat: NumberFormat = defaultNumberFormat) -> OperationCapsuleContent? {
        let operations = repository.operations
        if let current = operations.current {
            switch current.phase {
            case .conflicted:
                return .conflicted(message: current.conflictsMessage)
            case .interrupted:
                return .interrupted(message: current.interruptedMessage)
            case .running(let progress), .continuing(let progress):
                return running(name: name(of: current), progress: progress, numberFormat: numberFormat)
            }
        }
        if operations.conflictState != nil {
            return .conflicted(message: "Resolve conflicts to continue.")
        }
        guard let local = repository.localOperation, let name = name(of: local.kind) else {
            return repository.gitState.inProgress?.unsupportedSummary.map { .unsupported(message: $0) }
        }
        switch local.progress {
        case .multiCommitOperation(let progress)?:
            return running(name: name, progress: progress, numberFormat: numberFormat)
        case .revert(let progress)?:
            return .running(title: "\(name) in progress", detail: progress.description, progress: progress.value)
        default:
            return .running(title: "\(name) in progress", detail: nil, progress: nil)
        }
    }

    private static func running(name: String, progress: MultiCommitOperationProgress, numberFormat: NumberFormat) -> OperationCapsuleContent {
        var detail: String?
        if progress.totalCommitCount > 0 {
            detail = "Commit \(formatCount(progress.position, numberFormat)) of \(formatCount(progress.totalCommitCount, numberFormat))"
            if !progress.currentCommitSummary.isEmpty {
                detail! += " · \(RichText.emojified(progress.currentCommitSummary))"
            }
        }
        return .running(title: "\(name) in progress", detail: detail, progress: progress.value)
    }

    private static func name(of operation: MultiCommitOperation) -> String {
        if case .revert = operation.detail {
            return "Revert"
        }
        return operation.kind.rawValue
    }

    /// The display name of a multi-commit operation kind.
    private static func name(of kind: OperationKind) -> String? {
        switch kind {
        case .merge, .finishMerge: "Merge"
        case .rebase, .continueRebase: "Rebase"
        case .cherryPick, .continueCherryPick: "Cherry-pick"
        case .squash: "Squash"
        case .reorder: "Reorder"
        case .revert, .continueRevert: "Revert"
        default: nil
        }
    }
}


/// The floating pillow: progress while an operation runs, or the note that
/// it waits for the user, with a button that goes to Changes. Its badge says
/// which: honey and turning while work runs, apricot while it waits on
/// conflicts or a rebase in between, slate for what only git can finish.
/// It can't be dismissed while the operation exists.
public struct OperationCapsule: View {
    private let content: OperationCapsuleContent
    private let onView: () -> Void
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - onView: View Conflicts or View Rebase: shows the operation in
    ///     Changes; Open in Terminal opens the repository in the shell.
    public init(_ content: OperationCapsuleContent, onView: @escaping () -> Void = {}) {
        self.content = content
        self.onView = onView
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Pillow.height / 2, style: .continuous)
        Group {
            switch content {
            case .running(let title, let detail, let progress):
                HStack(spacing: Metrics.Pillow.spacing) {
                    RunningTile()
                    VStack(alignment: .leading, spacing: Metrics.OperationPillow.lineSpacing) {
                        Text(title)
                            .font(Typography.pillowMessage)
                            .foregroundStyle(.text)
                            .lineLimit(1)
                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .font(Typography.pillowDetail)
                                .foregroundStyle(.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if let progress {
                            CapsuleProgressBar(value: progress, tint: TileMood.running.color)
                                .frame(minWidth: Metrics.OperationPillow.progressMinimumWidth)
                                .padding(.top, Metrics.OperationPillow.progressTopPadding)
                        }
                    }
                }
                .padding(.leading, (Metrics.Pillow.height - Metrics.Tiles.floating) / 2)
                .padding(.trailing, Metrics.Pillow.height / 2)
                .padding(.vertical, Metrics.insetSmall)
                .accessibilityElement(children: .combine)

            case .conflicted(let message):
                waiting(message: message, mood: .waiting, systemImage: "exclamationmark.triangle", buttonTitle: "View Conflicts")

            case .interrupted(let message):
                waiting(message: message, mood: .waiting, systemImage: "pause", buttonTitle: "View Rebase")

            case .unsupported(let message):
                waiting(message: message, mood: .notice, systemImage: "terminal", buttonTitle: "Open in Terminal")
            }
        }
        .frame(minHeight: Metrics.Pillow.height)
        .floatingWidth()
        .pillowSurface(in: shape)
    }

    /// An operation waiting for the user: its badge, the message, and the
    /// button that shows it in Changes.
    private func waiting(message: String, mood: TileMood, systemImage: String, buttonTitle: String) -> some View {
        HStack(spacing: Metrics.Pillow.spacing) {
            MoodBadge(mood: mood, systemImage: systemImage)
                .accessibilityElement()
                .accessibilityLabel("Warning")
            Text(message)
                .font(Typography.pillowMessage)
                .foregroundStyle(.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: onView)
                .buttonStyle(.prominent)
                .controlSize(.regular)
        }
        .padding(.leading, (Metrics.Pillow.height - Metrics.Tiles.floating) / 2)
        .padding(.trailing, (Metrics.Pillow.height - Metrics.ControlHeight.regular) / 2)
        .padding(.vertical, Metrics.insetSmall)
    }
}

/// The running badge: a soft honey circle, its arrows turning while work
/// runs; still with Reduce Motion.
private struct RunningTile: View {
    @Environment(\.motion) private var motion

    var body: some View {
        let size = Metrics.Tiles.floating
        let color = TileMood.running.color
        Circle()
            .fill(Color(nsColor: Palette.tint(color, light: Metrics.Tiles.softAlpha.light, dark: Metrics.Tiles.softAlpha.dark)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: size * Metrics.PlaceTiles.symbolRatio, weight: .heavy))
                    .foregroundStyle(Color(nsColor: color))
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !motion.reduceMotion)
            }
            .accessibilityHidden(true)
    }
}

extension Metrics {
    /// The operation capsule's running pillow.
    public enum OperationPillow {
        /// Between its title, its detail, and its progress.
        public static let lineSpacing: CGFloat = 2
        /// Above the progress bar.
        public static let progressTopPadding: CGFloat = 4
        /// The progress bar is at least this wide.
        public static let progressMinimumWidth: CGFloat = 220
    }
}
