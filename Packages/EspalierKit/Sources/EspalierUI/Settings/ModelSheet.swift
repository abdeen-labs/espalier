// Adding or editing one of a provider's models, as a sheet over the provider
// sheet, with its fields, hints, and validation (AIKit's
// `validateBYOKModelForm` and `makeBYOKModel`). The model goes back to the
// provider sheet; nothing is saved until the provider is.

import AIKit
import EspalierCore
import SwiftUI

/// The model sheet's fields and validation.
@MainActor @Observable
final class ModelEditor {
    let isEditing: Bool
    /// The other models' identifiers, which this one must not reuse.
    let otherModelIds: [String]
    var form: BYOKModelForm {
        didSet {
            // Once saving was tried, the message follows the fields.
            if hasTriedSaving {
                problem = validateBYOKModelForm(form, otherModelIds: otherModelIds)
            }
        }
    }
    /// Why the model can't be saved, after trying.
    private(set) var problem: String?
    private var hasTriedSaving = false

    /// - Parameters:
    ///   - model: The model being edited, or nil to add one.
    ///   - otherModelIds: `otherBYOKModelIds` of the provider form's models.
    init(model: BYOKModel?, otherModelIds: [String]) {
        isEditing = model != nil
        self.otherModelIds = otherModelIds
        form = BYOKModelForm(editing: model)
    }

    var title: String {
        isEditing ? "Edit Model" : "Add Model"
    }

    var saveTitle: String {
        isEditing ? "Save" : "Add"
    }

    /// The model to save, or nil with `problem` set.
    func save() -> BYOKModel? {
        hasTriedSaving = true
        problem = validateBYOKModelForm(form, otherModelIds: otherModelIds)
        return problem == nil ? makeBYOKModel(from: form) : nil
    }
}

/// The model sheet: its name, identifier, and reasoning effort in a column
/// form, with what each means under them.
struct ModelSheet: View {
    static let sheetID = "espalier.settings.aiModel"

    @State private var editor: ModelEditor
    private let onSave: (BYOKModel) -> Void
    /// Set once the model went back to the provider sheet: another click
    /// while this sheet closes adds nothing.
    @State private var didSave = false
    @Environment(\.dismissModal) private var dismiss

    init(editor: ModelEditor, onSave: @escaping (BYOKModel) -> Void) {
        _editor = State(initialValue: editor)
        self.onSave = onSave
    }

    var body: some View {
        @Bindable var editor = editor
        SheetScaffold(editor.title) {
            Form {
                LabeledContent("Display Name") {
                    TextField("Display Name", text: $editor.form.name, prompt: Text(verbatim: "GPT-4o"))
                        .labelsHidden()
                }
                LabeledContent("Model Identifier") {
                    TextField("Model Identifier", text: $editor.form.id, prompt: Text(verbatim: "gpt-4o"))
                        .labelsHidden()
                }
                LabeledContent {
                    SettingsNote("The display name is what the model pickers show. The identifier is the exact name your provider expects, such as gpt-4o or llama3.")
                } label: {
                    EmptyView()
                }
                LabeledContent("Reasoning Effort") {
                    CapsulePopUp("Reasoning Effort", selection: $editor.form.reasoningEffort, title: reasoningTitle(editor.form.reasoningEffort)) {
                        MenuChoice("Default (provider's choice)", value: ReasoningEffort?.none)
                        for effort in ReasoningEffortOrder {
                            MenuChoice(formatReasoningEffort(effort), value: Optional(effort))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent {
                    SettingsNote("Reasoning models, such as o3 or GPT-5, think before they answer. Higher levels are slower but do better on complex tasks. Leave it on Default for other models, or to let the provider choose.")
                } label: {
                    EmptyView()
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)

            if let problem = editor.problem {
                FieldMessage(problem, kind: .error)
            }
        } buttons: {
            SheetButtons(editor.saveTitle, cancel: { dismiss() }) {
                guard !didSave, let model = editor.save() else {
                    return
                }
                didSave = true
                onSave(model)
                dismiss()
            }
        }
    }

    private func reasoningTitle(_ effort: ReasoningEffort?) -> String {
        effort.map(formatReasoningEffort) ?? "Default (provider's choice)"
    }
}
