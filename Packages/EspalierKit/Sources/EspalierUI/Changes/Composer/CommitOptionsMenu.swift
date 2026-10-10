// The composer's Options menu: Amend Last Commit, then the commit options:
// Bypass Commit Hooks, Add Signed-off-by Trailer, and Allow Empty Commit,
// which resets after each commit.

import EspalierCore
import GitKit
import SwiftUI

/// The options the menu shows.
nonisolated public struct CommitOptionsContent: Sendable, Equatable {
    public var isAmending: Bool
    /// Whether amending can start or stop now.
    public var canToggleAmend: Bool
    public var options: CommitOptions
    /// Whether the options can change (not while committing).
    public var isEnabled: Bool

    public init(isAmending: Bool = false, canToggleAmend: Bool = true, options: CommitOptions = CommitOptions(), isEnabled: Bool = true) {
        self.isAmending = isAmending
        self.canToggleAmend = canToggleAmend
        self.options = options
        self.isEnabled = isEnabled
    }

    /// Whether every option is off (the button looks plain).
    public var isDefault: Bool {
        !isAmending && !options.skipHooks && !options.signOff && !options.allowEmpty
    }
}

/// The commit options: an ellipsis in a soft circle in the commit message
/// card's footer, tinted while an option is on, and its menu.
public struct CommitOptionsMenu: View {
    private let content: CommitOptionsContent
    private let onToggleAmend: () -> Void
    private let onChange: (CommitOptions) -> Void

    /// - Parameters:
    ///   - onToggleAmend: Starts or stops amending the last commit.
    ///   - onChange: Applies the commit options.
    public init(_ content: CommitOptionsContent, onToggleAmend: @escaping () -> Void = {}, onChange: @escaping (CommitOptions) -> Void = { _ in }) {
        self.content = content
        self.onToggleAmend = onToggleAmend
        self.onChange = onChange
    }

    public var body: some View {
        Menu {
            Toggle("Amend Last Commit", isOn: Binding(
                get: { content.isAmending },
                set: { _ in onToggleAmend() }
            ))
            .disabled(!content.canToggleAmend)
            Divider()
            option("Bypass Commit Hooks", \.skipHooks)
            option("Add Signed-off-by Trailer", \.signOff)
            option("Allow Empty Commit", \.allowEmpty)
        } label: {
            IconCircle("ellipsis", size: ComposerMetrics.footerButtonSize, tint: content.isDefault ? nil : Color.accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!content.isEnabled)
        .opacity(content.isEnabled ? 1 : CheckboxDrawing.disabledOpacity)
        .help("Commit Options")
        .accessibilityLabel("Commit Options")
    }

    private func option(_ title: String, _ keyPath: WritableKeyPath<CommitOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { content.options[keyPath: keyPath] },
            set: { isOn in
                var options = content.options
                options[keyPath: keyPath] = isOn
                onChange(options)
            }
        ))
    }
}
