// Settings ▸ Prompts: the ten confirmations, what switching branches does
// with uncommitted changes, and the commit length warning. Each change is
// written at once (`Preferences`).

import EspalierCore
import GitKit
import SwiftUI

/// Settings ▸ Prompts.
public struct PromptsPane: View {
    private let model: AppModel?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            PromptsForm(preferences: model.preferences)
        } else {
            SettingsPanePlaceholder(tab: .prompts)
        }
    }
}

/// The confirmations, with the setting each toggles.
@MainActor
enum PromptSettings {
    static let confirmations: [(title: String, setting: ReferenceWritableKeyPath<Preferences, Bool>)] = [
        ("Removing repositories", \.confirmRepositoryRemoval),
        ("Discarding changes", \.confirmDiscardChanges),
        ("Discarding changes permanently", \.confirmDiscardChangesPermanently),
        ("Discarding a stash", \.confirmDiscardStash),
        ("Checking out a commit", \.confirmCheckoutCommit),
        ("Force pushing", \.confirmForcePush),
        ("Undoing a commit", \.confirmUndoCommit),
        ("Replacing a message with a generated one", \.confirmCommitMessageOverride),
        ("Removing worktrees", \.confirmWorktreeRemoval),
        ("Committing changes hidden by a filter", \.confirmCommitFilteredChanges),
    ]

    /// The switch-branch choices.
    static let strategies: [(title: String, strategy: UncommittedChangesStrategy)] = [
        ("Ask me where my changes should go", .askForConfirmation),
        ("Always bring my changes to the new branch", .moveToNewBranch),
        ("Always stash them on the current branch", .stashOnCurrentBranch),
    ]
}

/// The Prompts pane: a switch per confirmation, the switch-branch choice as
/// radio rows, and the commit length warning.
struct PromptsForm: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsPage {
            SettingsSection("Ask before") {
                ForEach(PromptSettings.confirmations, id: \.title) { confirmation in
                    SettingsToggleRow(confirmation.title, isOn: $preferences[dynamicMember: confirmation.setting])
                }
            }
            SettingsSection("Switching branches with changes") {
                RadioList(
                    "Switching branches with changes",
                    selection: $preferences.uncommittedChangesStrategy,
                    choices: PromptSettings.strategies.map { ChoiceListItem($0.title, value: $0.strategy) }
                )
            }
            SettingsSection("Commit messages") {
                SettingsToggleRow(
                    "Warn when a summary is long",
                    description: "Shows a hint while a commit's summary runs past 50 characters.",
                    isOn: $preferences.showCommitLengthWarning
                )
            }
        }
    }
}
