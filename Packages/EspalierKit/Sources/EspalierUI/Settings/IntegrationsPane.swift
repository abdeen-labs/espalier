// Settings ▸ Integrations: the external editor and shell pop-ups, each with
// "Configure Custom Editor…" (or Shell…), and the hint when no editor is
// found. Choosing an editor or shell applies at once (`IntegrationsModel`);
// a custom one is configured in a sheet (CustomIntegrationForm.swift) and
// saved only once it's valid.
//
// Showing the pane never changes the editor or shell: a selected one that
// isn't installed shows as not installed until the user picks another. The
// GitHub Desktop links switch shows the setting, which only the switch
// changes.

import EspalierCore
import GitKit
import SwiftUI

/// Settings ▸ Integrations.
public struct IntegrationsPane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            IntegrationsForm(
                content: IntegrationsContent(model),
                actions: IntegrationsActions(app: model, modals: context?.modals, presenter: context?.presenter)
            )
        } else {
            SettingsPanePlaceholder(tab: .integrations)
        }
    }
}

/// An item of the editor or shell pop-up.
nonisolated enum IntegrationChoice: Hashable, Sendable {
    /// An editor or shell by name.
    case named(String)
    /// The saved custom editor or shell.
    case custom
    /// "Configure Custom Editor…" (or Shell…): opens the sheet.
    case configure
    /// No editor is installed or selected.
    case none
}

/// What one pop-up shows.
nonisolated struct IntegrationPopUp: Equatable, Sendable {
    /// The installed editors or shells, by name.
    var installed: [String]
    /// The current choice.
    var selection: IntegrationChoice
    /// A selected editor or shell that isn't installed (or not yet looked
    /// up).
    var missing: String?
    /// The saved custom integration, if any.
    var custom: CustomIntegration?
    /// Whether the installed ones are still being looked up (launch), so a
    /// selection that isn't listed yet isn't called missing.
    var isLookingUp = false

    /// The item for `missing`.
    var missingTitle: String? {
        missing.map { isLookingUp ? $0 : "\($0) (Not Installed)" }
    }

    /// The custom integration's name in the pop-up: the application's name,
    /// or the executable's.
    var customTitle: String? {
        custom.map { IntegrationPopUp.displayName(ofPath: $0.path) }
    }

    static func displayName(ofPath path: String) -> String {
        let name = URL(filePath: path).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// What the Integrations pane shows.
nonisolated struct IntegrationsContent: Equatable, Sendable {
    var editor: IntegrationPopUp
    var shell: IntegrationPopUp
    /// "No other editors found. Install Visual Studio Code?"
    var showsNoEditorsHint: Bool
    /// Whether GitHub Desktop links open in Espalier: the value being
    /// applied, else the setting.
    var opensGitHubDesktopLinks: Bool

    init(editor: IntegrationPopUp, shell: IntegrationPopUp, showsNoEditorsHint: Bool, opensGitHubDesktopLinks: Bool = false) {
        self.editor = editor
        self.shell = shell
        self.showsNoEditorsHint = showsNoEditorsHint
        self.opensGitHubDesktopLinks = opensGitHubDesktopLinks
    }

    /// The pane for the app's settings and what's installed.
    @MainActor
    init(_ app: AppModel) {
        let integrations = app.integrations
        let settings = app.preferences.integrations

        let isLookingUp = !integrations.hasLoadedIntegrations
        let editors = integrations.availableEditors.map(\.editor)
        var editorSelection = IntegrationChoice.none
        var missingEditor: String?
        if settings.activeCustomEditor != nil {
            editorSelection = .custom
        } else if let selected = settings.selectedExternalEditor {
            editorSelection = .named(selected)
            if !editors.contains(selected) {
                missingEditor = selected
            }
        } else if let first = editors.first {
            editorSelection = .named(first)
        }

        let shells = integrations.availableShells.map(\.shell.rawValue)
        var shellSelection = IntegrationChoice.named(settings.selectedShell.rawValue)
        var missingShell: String?
        if settings.activeCustomShell != nil {
            shellSelection = .custom
        } else if !shells.contains(settings.selectedShell.rawValue) {
            missingShell = settings.selectedShell.rawValue
        }

        self.init(
            editor: IntegrationPopUp(installed: editors, selection: editorSelection, missing: missingEditor, custom: settings.customEditor, isLookingUp: isLookingUp),
            shell: IntegrationPopUp(installed: shells, selection: shellSelection, missing: missingShell, custom: settings.customShell, isLookingUp: isLookingUp),
            showsNoEditorsHint: !isLookingUp && editors.isEmpty,
            opensGitHubDesktopLinks: integrations.opensGitHubDesktopLinks
        )
    }
}

/// What the Integrations pane's controls do.
@MainActor
struct IntegrationsActions {
    let app: AppModel
    /// The Settings window's modals, for the custom integration sheet.
    let modals: ModalPresenter?
    /// The Settings window's presenter, for the errors of giving GitHub
    /// Desktop links to Espalier or back.
    var presenter: WindowPresenter? = nil

    /// Picks an editor from the pop-up.
    func chooseEditor(_ choice: IntegrationChoice) {
        let integrations = app.integrations
        switch choice {
        case .named(let name):
            integrations.selectEditor(name)
        case .custom:
            // Using the saved custom editor again validates it first; one
            // that no longer validates (its app was deleted) opens the sheet.
            guard let custom = app.preferences.integrations.customEditor else {
                configure(.editor)
                return
            }
            Task {
                let validation = await integrations.setCustomEditor(path: custom.path, arguments: custom.arguments)
                if !validation.isValid {
                    configure(.editor)
                }
            }
        case .configure:
            configure(.editor)
        case .none:
            break
        }
    }

    /// Picks a shell from the pop-up.
    func chooseShell(_ choice: IntegrationChoice) {
        let integrations = app.integrations
        switch choice {
        case .named(let name):
            integrations.selectShell(Shell.parse(name))
        case .custom:
            guard let custom = app.preferences.integrations.customShell else {
                configure(.shell)
                return
            }
            Task {
                let validation = await integrations.setCustomShell(path: custom.path, arguments: custom.arguments)
                if !validation.isValid {
                    configure(.shell)
                }
            }
        case .configure:
            configure(.shell)
        case .none:
            break
        }
    }

    /// Opens the custom editor or shell sheet, starting from the saved one.
    func configure(_ kind: CustomIntegrationKind) {
        guard let modals else {
            return
        }
        let settings = app.preferences.integrations
        let saved = kind == .editor ? settings.customEditor : settings.customShell
        let editor = CustomIntegrationEditor(kind: kind, integrations: app.integrations, saved: saved)
        modals.presentSheet(id: CustomIntegrationSheet.sheetID) {
            CustomIntegrationSheet(editor: editor)
        }
    }

    /// "Install Visual Studio Code?": its download page.
    func openSuggestedEditorPage() {
        if let url = URL(string: suggestedExternalEditor.url) {
            app.integrations.openInBrowser(url)
        }
    }

    /// Gives GitHub Desktop links to Espalier, or back to GitHub Desktop.
    /// A failure shows in the presenter, and the switch goes back.
    func setOpenGitHubDesktopLinks(_ isOn: Bool) async {
        let integrations = app.integrations
        guard let presenter else {
            try? await integrations.setOpenGitHubDesktopLinks(isOn)
            return
        }
        await presenter.perform { _ throws(OperationError) in
            try await integrations.setOpenGitHubDesktopLinks(isOn)
        }
    }
}

/// The Integrations pane: the editor, the shell, and GitHub Desktop links.
struct IntegrationsForm: View {
    let content: IntegrationsContent
    let actions: IntegrationsActions?
    /// Bumped after "Configure…" is picked, so the pop-up goes back to the
    /// current choice.
    @State private var editorRevision = 0
    @State private var shellRevision = 0

    var body: some View {
        SettingsPage {
            SettingsSection("External editor") {
                SettingsRow("Editor", description: "Used by Open in External Editor.", labelsControl: true) {
                    IntegrationPicker(title: "Editor", popUp: content.editor, configureTitle: "Configure Custom Editor…", selection: Binding {
                        content.editor.selection
                    } set: { choice in
                        if choice == .configure {
                            editorRevision += 1
                        }
                        actions?.chooseEditor(choice)
                    })
                    .id(editorRevision)
                }
                if let custom = content.editor.custom, content.editor.selection == .custom {
                    CustomIntegrationSummary(integration: custom)
                }
                if content.showsNoEditorsHint {
                    SettingsMessageRow {
                        HStack(spacing: Metrics.grid) {
                            Text("No other editors found.")
                                .foregroundStyle(.text3)
                            Button("Install \(suggestedExternalEditor.name)?") {
                                actions?.openSuggestedEditorPage()
                            }
                            .buttonStyle(.link)
                        }
                        .font(Typography.secondary)
                    }
                }
            }

            SettingsSection("Shell") {
                SettingsRow("Shell", description: "Used by Open in Terminal.", labelsControl: true) {
                    IntegrationPicker(title: "Shell", popUp: content.shell, configureTitle: "Configure Custom Shell…", selection: Binding {
                        content.shell.selection
                    } set: { choice in
                        if choice == .configure {
                            shellRevision += 1
                        }
                        actions?.chooseShell(choice)
                    })
                    .id(shellRevision)
                }
                if let custom = content.shell.custom, content.shell.selection == .custom {
                    CustomIntegrationSummary(integration: custom)
                }
            }

            SettingsSection("Links") {
                SettingsToggleRow(
                    "Open GitHub Desktop links in Espalier",
                    description: "When you click Open with GitHub Desktop on GitHub, the repository opens here.",
                    isOn: Binding {
                        content.opensGitHubDesktopLinks
                    } set: { isOn in
                        guard let actions else {
                            return
                        }
                        Task { await actions.setOpenGitHubDesktopLinks(isOn) }
                    }
                )
            }
        }
    }
}

/// An editor or shell pop-up: the installed ones, a choice that isn't
/// installed, the saved custom one, and "Configure Custom…".
struct IntegrationPicker: View {
    let title: String
    let popUp: IntegrationPopUp
    let configureTitle: String
    @Binding var selection: IntegrationChoice

    var body: some View {
        CapsulePopUp(title, selection: $selection, title: selectionTitle) {
            if popUp.selection == .none {
                Text("None").tag(IntegrationChoice.none)
            }
            ForEach(popUp.installed, id: \.self) { name in
                Text(name).tag(IntegrationChoice.named(name))
            }
            if let missing = popUp.missing, let title = popUp.missingTitle {
                Text(title).tag(IntegrationChoice.named(missing))
            }
            Divider()
            if let customTitle = popUp.customTitle {
                Text("Custom: \(customTitle)").tag(IntegrationChoice.custom)
            }
            Text(configureTitle).tag(IntegrationChoice.configure)
        }
        .settingsControlWidth()
    }

    /// The chosen item's title.
    private var selectionTitle: String {
        switch popUp.selection {
        case .none, .configure:
            "None"
        case .custom:
            popUp.customTitle.map { "Custom: \($0)" } ?? "Custom"
        case .named(let name):
            name == popUp.missing ? popUp.missingTitle ?? name : name
        }
    }
}

/// The custom editor or shell in use: its path and arguments.
struct CustomIntegrationSummary: View {
    let integration: CustomIntegration

    var body: some View {
        SettingsRow("Command") {
            Text("\(integration.path) \(integration.arguments)")
                .font(Typography.sha)
                .foregroundStyle(.text2)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}
