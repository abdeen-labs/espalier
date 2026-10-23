// Open With (⌥⇧⌘A): the editors' pop-up, as Settings ▸ Integrations shows
// it (`IntegrationPicker`), with the detected editors and "Configure Custom
// Editor…", whose Path and Arguments show under it and are checked as
// Settings checks them; Open opens once, without changing the settings
// (`openWith`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Open With's state.
@MainActor @Observable
final class OpenWithModel {
    @ObservationIgnored let integrations: IntegrationsModel
    let path: String
    /// An editor by name, or `.configure` for the custom editor's fields.
    var choice: IntegrationChoice
    var customPath = ""
    var customArguments = TargetPathArgument
    /// The custom fields' check, once it has run for them.
    private(set) var validation: CustomIntegrationValidation?

    /// Preselects the editor chosen in Settings: the custom editor, with
    /// its path and arguments, or the selected editor when it's installed.
    /// Without either, the first editor; with none installed, the custom
    /// editor's fields.
    init(integrations: IntegrationsModel, settings: IntegrationSettings, path: String) {
        self.integrations = integrations
        self.path = path
        if let custom = settings.activeCustomEditor {
            choice = .configure
            customPath = custom.path
            customArguments = custom.arguments
        } else if let selected = integrations.editorResolution.selectedEditor {
            choice = .named(selected.editor)
        } else {
            choice = integrations.availableEditors.first.map { .named($0.editor) } ?? .configure
        }
    }

    var editors: [FoundEditor] {
        integrations.availableEditors
    }

    /// The editors' pop-up: the detected editors and "Configure Custom
    /// Editor…".
    var popUp: IntegrationPopUp {
        IntegrationPopUp(installed: editors.map(\.editor), selection: choice)
    }

    /// The check of the custom fields as they are now.
    var currentValidation: CustomIntegrationValidation? {
        guard let validation, validation.path == customPath, validation.arguments == customArguments else {
            return nil
        }
        return validation
    }

    func validate() async {
        let path = customPath
        let arguments = customArguments
        let result = await integrations.validateCustomIntegration(path: path, arguments: arguments)
        if result.path == customPath, result.arguments == customArguments {
            validation = result
        }
    }

    /// Whether Open can be pressed: an editor, or a valid custom one.
    var canOpen: Bool {
        switch choice {
        case .named: true
        case .configure: currentValidation?.isValid ?? false
        case .custom, .none: false
        }
    }

    func open(presenter: WindowPresenter) async {
        let integrations = integrations
        let path = path
        switch choice {
        case .named(let name):
            guard let editor = editors.first(where: { $0.editor == name }) else {
                return
            }
            await presenter.perform { _ throws(OperationError) in
                try await integrations.openWith(path, editor: editor)
            }
        case .configure:
            guard let integration = currentValidation?.integration else {
                return
            }
            await presenter.perform { _ throws(OperationError) in
                try await integrations.openWith(path, customEditor: integration)
            }
        case .custom, .none:
            break
        }
    }
}

/// Open With's form.
struct OpenWithForm: View {
    @Bindable var model: OpenWithModel
    var cancel: () -> Void = {}
    var open: () -> Void = {}

    var body: some View {
        SheetScaffold("Open With") {
            Form {
                // The labels in the form's column; the fields are capsules,
                // and the pop-up as wide as they are.
                LabeledContent("Editor") {
                    IntegrationPicker(title: "Editor", popUp: model.popUp, configureTitle: "Configure Custom Editor…", selection: $model.choice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.choice == .configure {
                    FolderField(label: "Path", path: $model.customPath, prompt: "Path to executable") {
                        choosePath()
                    }
                    .barTransition()
                    if !model.customPath.isEmpty, let error = model.currentValidation?.pathError {
                        FieldMessage(error, kind: .error)
                    }
                    LabeledContent("Arguments") {
                        TextField("Arguments", text: $model.customArguments, prompt: Text("Command line arguments").fieldPrompt())
                            .labelsHidden()
                    }
                    .barTransition()
                    if let error = model.currentValidation?.argumentsError {
                        FieldMessage(error, kind: .error)
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        } buttons: {
            SheetButtons("Open", isConfirmDisabled: !model.canOpen, cancel: cancel, confirm: open)
        }
        // The custom editor's fields grow in over 0.22 s and leave over 0.15
        // s, the buttons moving with them; their checks, as they're typed,
        // show at once.
        .barMotion(model.choice == .configure)
        .task(id: [model.customPath, model.customArguments]) {
            await model.validate()
        }
    }

    /// Choose…: an application or an executable (applications are folders,
    /// so both can be chosen).
    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let model = model
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                model.customPath = AddRepositoryPanel.folderPath(url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// The Open With sheet.
struct OpenWithSheet: View {
    static let sheetID = "repository.openWith"

    @State var model: OpenWithModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    var body: some View {
        OpenWithForm(model: model, cancel: { dismiss() }) {
            let model = model
            let presenter = context.presenter
            dismiss()
            Task { await model.open(presenter: presenter) }
        }
    }

    static func present(path: String, in context: WindowContext) {
        let model = OpenWithModel(integrations: context.app.integrations, settings: context.app.preferences.integrations, path: path)
        context.modals.presentSheet(id: sheetID) {
            OpenWithSheet(model: model)
        }
    }
}
