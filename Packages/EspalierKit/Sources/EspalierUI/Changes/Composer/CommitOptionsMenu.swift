// The composer's Options menu: Amend Last Commit, then the commit options:
// Bypass Commit Hooks, Add Signed-off-by Trailer, and Allow Empty Commit,
// which resets after each commit. Committing with AI, Push After Committing
// takes Amend Last Commit's place.

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
    /// Committing with AI: no amending, and the push choice.
    public var isAssisted: Bool
    /// Whether assisted commits are pushed once they're made.
    public var pushesAfterCommitting: Bool

    public init(
        isAmending: Bool = false,
        canToggleAmend: Bool = true,
        options: CommitOptions = CommitOptions(),
        isEnabled: Bool = true,
        isAssisted: Bool = false,
        pushesAfterCommitting: Bool = false
    ) {
        self.isAmending = isAmending
        self.canToggleAmend = canToggleAmend
        self.options = options
        self.isEnabled = isEnabled
        self.isAssisted = isAssisted
        self.pushesAfterCommitting = pushesAfterCommitting
    }

    /// Whether every option is off (the button looks plain).
    public var isDefault: Bool {
        !isAmending && !options.skipHooks && !options.signOff && !options.allowEmpty && !(isAssisted && pushesAfterCommitting)
    }
}

/// The commit options: an icon button in the commit message card's footer,
/// its circled ellipsis filling in the accent while an option is on, and
/// its menu.
public struct CommitOptionsMenu: View {
    private let content: CommitOptionsContent
    private let onToggleAmend: () -> Void
    private let onTogglePush: () -> Void
    private let onChange: (CommitOptions) -> Void

    /// - Parameters:
    ///   - onToggleAmend: Starts or stops amending the last commit.
    ///   - onTogglePush: Turns pushing after assisted commits on or off.
    ///   - onChange: Applies the commit options.
    public init(
        _ content: CommitOptionsContent,
        onToggleAmend: @escaping () -> Void = {},
        onTogglePush: @escaping () -> Void = {},
        onChange: @escaping (CommitOptions) -> Void = { _ in }
    ) {
        self.content = content
        self.onToggleAmend = onToggleAmend
        self.onTogglePush = onTogglePush
        self.onChange = onChange
    }

    public var body: some View {
        PullDownButton("Commit Options") {
            if content.isAssisted {
                MenuToggle("Push After Committing", isOn: content.pushesAfterCommitting, action: onTogglePush)
            } else {
                MenuToggle("Amend Last Commit", isOn: content.isAmending, action: onToggleAmend)
                    .disabled(!content.canToggleAmend)
            }
            MenuDivider()
            option("Bypass Commit Hooks", \.skipHooks)
            option("Add Signed-off-by Trailer", \.signOff)
            option("Allow Empty Commit", \.allowEmpty)
        } label: {
            Label {
                Text("Commit Options")
            } icon: {
                Image(systemName: content.isDefault ? "ellipsis.circle" : "ellipsis.circle.fill")
                    .foregroundStyle(content.isDefault ? AnyShapeStyle(.text2) : AnyShapeStyle(Color.accent))
            }
        }
        .buttonStyle(.icon)
        .fixedSize()
        .disabled(!content.isEnabled)
        .tooltip("Commit Options")
    }

    private func option(_ title: String, _ keyPath: WritableKeyPath<CommitOptions, Bool>) -> MenuToggle {
        let isOn = content.options[keyPath: keyPath]
        return MenuToggle(title, isOn: isOn) { [content, onChange] in
            var options = content.options
            options[keyPath: keyPath] = !isOn
            onChange(options)
        }
    }
}
