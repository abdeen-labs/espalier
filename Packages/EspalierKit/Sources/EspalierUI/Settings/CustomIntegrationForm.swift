// Configuring a custom editor or shell, as a sheet: Path with Choose…,
// Arguments, and validation messages. It's saved, and used from then on,
// only once the path is an executable or an application and the arguments
// include `%TARGET_PATH%`
// (`IntegrationsModel.setCustomEditor(path:arguments:)`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Which custom integration a sheet configures.
nonisolated enum CustomIntegrationKind: Sendable, Equatable {
    case editor, shell

    var title: String {
        switch self {
        case .editor: "Custom Editor"
        case .shell: "Custom Shell"
        }
    }
}

/// The sheet's fields and their validation.
@MainActor @Observable
final class CustomIntegrationEditor {
    let kind: CustomIntegrationKind
    @ObservationIgnored let integrations: IntegrationsModel
    var path: String {
        didSet {
            if path != oldValue {
                hasEditedPath = true
            }
        }
    }
    var arguments: String
    /// The validation of the fields as they are, once checked.
    private(set) var validation: CustomIntegrationValidation?
    /// Whether the path was changed, or saving was tried: only then is an
    /// invalid path pointed out.
    private(set) var hasEditedPath = false
    private(set) var hasTriedSaving = false

    /// - Parameter saved: The saved custom integration, which the fields
    ///   start from; a new one starts with `%TARGET_PATH%` as its arguments.
    init(kind: CustomIntegrationKind, integrations: IntegrationsModel, saved: CustomIntegration?) {
        self.kind = kind
        self.integrations = integrations
        path = saved?.path ?? ""
        arguments = saved?.arguments ?? TargetPathArgument
    }

    /// Checks the fields as they are now.
    func validate() async {
        let path = path
        let arguments = arguments
        let result = await integrations.validateCustomIntegration(path: path, arguments: arguments)
        // A check that finished after the fields changed again is stale.
        if result.path == self.path, result.arguments == self.arguments {
            validation = result
        }
    }

    /// The validation, if it is of the fields as they are now.
    private var currentValidation: CustomIntegrationValidation? {
        guard let validation, validation.path == path, validation.arguments == arguments else {
            return nil
        }
        return validation
    }

    /// The message for a path that isn't an executable or an application.
    var pathError: String? {
        guard hasEditedPath || hasTriedSaving else {
            return nil
        }
        return currentValidation?.pathError
    }

    /// The message for arguments without `%TARGET_PATH%`.
    var argumentsError: String? {
        currentValidation?.argumentsError
    }

    /// Whether the fields can be saved.
    var canSave: Bool {
        currentValidation?.isValid ?? false
    }

    /// Saves the integration and uses it from now on, when it is valid.
    ///
    /// - Returns: Whether it was saved.
    @discardableResult
    func save() async -> Bool {
        hasTriedSaving = true
        let result = switch kind {
        case .editor: await integrations.setCustomEditor(path: path, arguments: arguments)
        case .shell: await integrations.setCustomShell(path: path, arguments: arguments)
        }
        if result.path == path, result.arguments == arguments {
            validation = result
        }
        return result.isValid
    }
}

/// The custom editor or shell sheet.
struct CustomIntegrationSheet: View {
    static let sheetID = "espalier.settings.customIntegration"

    @State private var editor: CustomIntegrationEditor
    @Environment(\.dismissModal) private var dismiss

    init(editor: CustomIntegrationEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        @Bindable var editor = editor
        SheetScaffold(editor.kind.title, message: "Espalier replaces \(TargetPathArgument) with the path to open.") {
            Form {
                LabeledContent("Path") {
                    VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                        HStack(spacing: Metrics.insetSmall) {
                            TextField("Path", text: $editor.path, prompt: Text("Path to executable"))
                                .labelsHidden()
                            Button("Choose…", action: choosePath)
                                .buttonStyle(.quiet)
                        }
                        if let error = editor.pathError {
                            FieldMessage(error, kind: .error)
                        }
                    }
                }
                LabeledContent("Arguments") {
                    VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                        TextField("Arguments", text: $editor.arguments, prompt: Text("Command line arguments"))
                            .labelsHidden()
                        if let error = editor.argumentsError {
                            FieldMessage(error, kind: .error)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        } buttons: {
            SheetButtons("Save", isConfirmDisabled: !editor.canSave, cancel: { dismiss() }) {
                Task {
                    if await editor.save() {
                        dismiss()
                    }
                }
            }
        }
        .task(id: [editor.path, editor.arguments]) {
            await editor.validate()
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
        let editor = editor
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                editor.path = url.path(percentEncoded: false)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
