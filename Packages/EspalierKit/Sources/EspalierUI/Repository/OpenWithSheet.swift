// Open With… (⌥⇧⌘A): the detected editors and "Configure Custom Editor…",
// whose Path and Arguments are checked as Settings checks them; Open opens
// once, without changing the settings (`openWith`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// What Open With opens with.
nonisolated enum OpenWithChoice: Hashable, Sendable {
    case editor(String)
    case custom
}

/// Open With's state.
@MainActor @Observable
final class OpenWithModel {
    @ObservationIgnored let integrations: IntegrationsModel
    let path: String
    var choice: OpenWithChoice?
    var customPath = ""
    var customArguments = TargetPathArgument
    /// The custom fields' check, once it has run for them.
    private(set) var validation: CustomIntegrationValidation?

    init(integrations: IntegrationsModel, path: String) {
        self.integrations = integrations
        self.path = path
        // The first editor; with none, the custom editor.
        choice = integrations.availableEditors.first.map { .editor($0.editor) } ?? .custom
    }

    var editors: [FoundEditor] {
        integrations.availableEditors
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
        case .editor?: true
        case .custom?: currentValidation?.isValid ?? false
        case nil: false
        }
    }

    func open(presenter: WindowPresenter) async {
        let integrations = integrations
        let path = path
        switch choice {
        case .editor(let name)?:
            guard let editor = editors.first(where: { $0.editor == name }) else {
                return
            }
            await presenter.perform { _ throws(OperationError) in
                try await integrations.openWith(path, editor: editor)
            }
        case .custom?:
            guard let integration = currentValidation?.integration else {
                return
            }
            await presenter.perform { _ throws(OperationError) in
                try await integrations.openWith(path, customEditor: integration)
            }
        case nil:
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
        SheetScaffold("Open With…") {
            Form {
                Picker("Select an editor", selection: $model.choice) {
                    ForEach(model.editors, id: \.editor) { editor in
                        Text(editor.editor).tag(Optional(OpenWithChoice.editor(editor.editor)))
                    }
                    if !model.editors.isEmpty {
                        Divider()
                    }
                    Text("Configure Custom Editor…").tag(Optional(OpenWithChoice.custom))
                }
                if model.choice == .custom {
                    FolderField(label: "Path", path: $model.customPath, prompt: "Path to executable") {
                        choosePath()
                    }
                    if !model.customPath.isEmpty, let error = model.currentValidation?.pathError {
                        SheetMessage(error, kind: .error)
                    }
                    LabeledContent("Arguments") {
                        TextField("Arguments", text: $model.customArguments, prompt: Text("Command line arguments"))
                            .labelsHidden()
                    }
                    if let error = model.currentValidation?.argumentsError {
                        SheetMessage(error, kind: .error)
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        } buttons: {
            SheetButtons("Open", isConfirmDisabled: !model.canOpen, cancel: cancel, confirm: open)
        }
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

/// Open With….
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
        let model = OpenWithModel(integrations: context.app.integrations, path: path)
        context.modals.presentSheet(id: sheetID) {
            OpenWithSheet(model: model)
        }
    }
}
