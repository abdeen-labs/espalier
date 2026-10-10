// Success outcomes as toasts. Their copy is the state layer's; they last 5 s,
// or 15 s with Undo, counted once the pointer leaves the toast, and the
// close button dismisses one at once. While a toast with Undo shows, Edit ▸
// Undo (⌘Z) runs it too, and its button shows the key (the window's undo
// manager; WindowPresenter).

import AppKit
import SwiftUI

/// A toast: a message, a symbol, and an optional Undo.
public struct Toast: Identifiable {
    public let id: UUID
    public var message: String
    public var systemImage: String
    public var undo: ToastAction?

    public init(id: UUID = UUID(), _ message: String, systemImage: String = "checkmark.circle.fill", undo: ToastAction? = nil) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.undo = undo
    }

    /// How long the toast stays once the pointer isn't over it.
    public var duration: Duration {
        undo == nil ? Timing.toast : Timing.toastWithUndo
    }

    /// The toast's look, for the view.
    public var content: ToastContent {
        ToastContent(message: message, systemImage: systemImage, undoTitle: undo?.title)
    }

    /// "Another operation is in progress".
    public static var busy: Toast {
        Toast("Another operation is in progress", systemImage: "hourglass")
    }
}

/// A toast's button.
public struct ToastAction {
    public var title: String
    public var perform: @MainActor () async -> Void

    public init(title: String = "Undo", perform: @escaping @MainActor () async -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// What a toast shows.
nonisolated public struct ToastContent: Sendable, Equatable {
    public var message: String
    public var systemImage: String
    /// The button's title, or nil for none.
    public var undoTitle: String?
    /// The key that also runs the button ("⌘Z"), as a key cap beside its
    /// title; nil where it doesn't run by key.
    public var undoShortcut: String?

    public init(message: String, systemImage: String = "checkmark.circle.fill", undoTitle: String? = nil, undoShortcut: String? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.undoTitle = undoTitle
        self.undoShortcut = undoShortcut
    }
}

/// Announces toasts to VoiceOver.
enum ToastAnnouncer {
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

/// One toast's capsule: the symbol, the message, Undo when there is one,
/// and the close button, spaced as the operation capsule.
public struct ToastView: View {
    private let content: ToastContent
    private let onUndo: () -> Void
    private let onClose: () -> Void

    public init(_ content: ToastContent, onUndo: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.content = content
        self.onUndo = onUndo
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: content.systemImage)
                .font(Typography.row)
                .imageScale(.large)
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityHidden(true)
            Text(content.message)
                .font(Typography.row)
                .foregroundStyle(.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let undoTitle = content.undoTitle {
                Button(action: onUndo) {
                    HStack(spacing: Metrics.insetSmall) {
                        Label(undoTitle, systemImage: "arrow.uturn.backward")
                        if let shortcut = content.undoShortcut {
                            KeyCap(shortcut)
                        }
                    }
                }
                .buttonStyle(.secondary)
                .controlSize(.regular)
            }
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.icon)
            .help("Close")
        }
        .padding(.leading, Metrics.insetMedium)
        .padding(.trailing, Metrics.insetSmall)
        .padding(.vertical, Metrics.insetSmall)
        .frame(minHeight: Metrics.Floating.height)
        .frame(maxWidth: Metrics.Floating.maximumWidth)
        .floatingSurface()
        // One element: the message, with Undo and Close as its actions.
        .accessibilityElement(children: .combine)
    }
}

/// The window's toasts, stacked, each timing out on its own. A toast rises
/// in over 0.22 s and leaves over 0.15 s; with Reduce Motion it comes and
/// goes at once.
struct ToastStack: View {
    let presenter: WindowPresenter
    @Environment(\.motion) private var motion

    var body: some View {
        ForEach(presenter.toasts) { toast in
            TimedToast(toast: toast, presenter: presenter)
                .transition(motion.animates ? Motion.floatingTransition : .identity)
        }
    }
}

/// A toast that closes after its duration, counted while the pointer isn't
/// over it.
struct TimedToast: View {
    let toast: Toast
    let presenter: WindowPresenter
    @State private var isHovering = false
    @Environment(\.motion) private var motion

    var body: some View {
        ToastView(content, onUndo: undo, onClose: close)
            .onHover { isHovering = $0 }
            .task(id: isHovering) {
                guard !isHovering else {
                    return
                }
                try? await Task.sleep(for: toast.duration)
                guard !Task.isCancelled else {
                    return
                }
                close()
            }
    }

    /// The toast's look, with ⌘Z beside Undo where Edit ▸ Undo runs it.
    var content: ToastContent {
        var content = toast.content
        if content.undoTitle != nil, presenter.undoesToastsByKey {
            content.undoShortcut = WindowPresenter.toastUndoKey
        }
        return content
    }

    /// Undo: closes the toast and runs its action, once. The toast stays on
    /// screen while it leaves; a second click finds it closed and runs
    /// nothing.
    func undo() {
        let action = withMotion(motion, Motion.leave) {
            presenter.takeToastUndo(toast.id)
        }
        if let action {
            Task { await action.perform() }
        }
    }

    private func close() {
        withMotion(motion, Motion.leave) {
            presenter.dismissToast(toast.id)
        }
    }
}
