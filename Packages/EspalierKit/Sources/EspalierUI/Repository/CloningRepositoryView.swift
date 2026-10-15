// A repository being cloned: "Cloning <name>", the progress (indeterminate
// until git reports some), git's description, and Cancel Clone (`cancel`).

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the cloning view shows.
nonisolated struct CloningContent: Sendable, Equatable {
    var name: String
    /// 0 to 1; 0 is indeterminate.
    var progress: Double
    /// Git's latest line, or the title ("Cloning into <path>").
    var description: String?
    var phase: CloneTask.Phase

    init(name: String, progress: Double, description: String?, phase: CloneTask.Phase) {
        self.name = name
        self.progress = progress
        self.description = description
        self.phase = phase
    }

    init(_ clone: CloneTask) {
        self.init(
            name: clone.name,
            progress: clone.progress?.value ?? 0,
            description: clone.progress?.description ?? clone.progress?.title,
            phase: clone.phase
        )
    }

    /// Whether Cancel Clone still stops it.
    var canCancel: Bool {
        phase == .cloning
    }
}

/// The cloning view's look, value-driven.
struct CloningForm: View {
    let content: CloningContent
    var cancel: () -> Void = {}

    var body: some View {
        VStack(spacing: Metrics.insetMedium) {
            IconCircle("arrow.down", size: Metrics.StateIcon.size, tint: .accent)
                .accessibilityHidden(true)
            Text("Cloning \(content.name)")
                .font(Typography.sheetTitle)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
            // A segment sweeps until git reports how far it has got.
            CapsuleProgressBar(value: content.progress > 0 ? content.progress : nil)
                .accessibilityLabel("Cloning \(content.name)")
            Text(statusLine)
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Button(content.phase == .cancelling ? "Cancelling…" : "Cancel Clone", action: cancel)
                .buttonStyle(.secondary)
                .disabled(!content.canCancel)
                .padding(.top, Metrics.grid)
        }
        .padding(Metrics.insetLarge * 2)
        .frame(maxWidth: CenteredMessageMetrics.maximumWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusLine: String {
        switch content.phase {
        case .cloning: content.description ?? " "
        case .cancelling: "Stopping the clone and removing what it cloned…"
        case .adding: "Adding the repository…"
        }
    }
}

/// The cloning view.
public struct CloningRepositoryView: View {
    private let clone: CloneTask
    @Environment(WindowContext.self) private var context

    public init(clone: CloneTask) {
        self.clone = clone
    }

    public var body: some View {
        CloningForm(content: CloningContent(clone)) {
            context.app.clones.cancel(clone.id)
        }
    }
}
