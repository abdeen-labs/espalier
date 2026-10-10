// Settings ▸ Advanced: background updates, the Move to Applications prompt's
// setting, and the command line tool and logs, which go through the window's
// actions.

import EspalierCore
import GitKit
import SwiftUI

/// Settings ▸ Advanced.
public struct AdvancedPane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            AdvancedForm(preferences: model.preferences, actions: context?.actions)
        } else {
            SettingsPanePlaceholder(tab: .advanced)
        }
    }
}

/// The Advanced pane: the Applications folder prompt, background updates,
/// and the command line tool and logs.
struct AdvancedForm: View {
    @Bindable var preferences: Preferences
    /// The Settings window's actions: the command line tool and the logs.
    let actions: WindowActions?

    var body: some View {
        SettingsPage {
            SettingsSection("General") {
                SettingsToggleRow(
                    "Ask to move Espalier to the Applications folder",
                    description: "When Espalier opens from somewhere else, like Downloads.",
                    isOn: $preferences.askToMoveToApplicationsFolder
                )
            }

            SettingsSection("Background updates") {
                SettingsToggleRow(
                    "Show status icons in the repository list",
                    description: "The icons show which repositories have local or remote changes, so repositories that aren't selected are fetched now and then. Turning this off doesn't stop fetching the selected repository, and may help with many repositories.",
                    isOn: $preferences.repositoryIndicatorsEnabled
                )
            }

            SettingsSection("Tools") {
                SettingsRow("Command line tool", description: "Open and clone repositories from Terminal with the espalier command.") {
                    actionButton(ActionKind.installCommandLineTool.title, .installCommandLineTool)
                }
                SettingsRow("Logs", description: "Saves this session's log to a file, for bug reports.") {
                    actionButton(ActionKind.showLogsInFinder.title, .showLogsInFinder)
                }
            }
        }
    }

    private func actionButton(_ title: String, _ action: ActionID) -> some View {
        Button(title) {
            actions?.perform(action)
        }
        .settingsButton()
        .disabled(!(actions?.canPerform(action) ?? false))
    }
}
