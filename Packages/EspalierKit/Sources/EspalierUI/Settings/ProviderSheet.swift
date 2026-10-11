// Adding or editing an AI provider, as a sheet, with its fields, copy, and
// validation (AIKit's `validateBYOKProviderForm` and `makeBYOKProvider`).
// Saving goes through `AIModel.addProvider`/`updateProvider(_:secret:)`,
// which store the secret in the keychain first; their errors show as alerts
// over the sheet.

import AIKit
import EspalierCore
import SwiftUI

/// The provider sheet's fields and validation.
@MainActor @Observable
final class ProviderEditor {
    @ObservationIgnored let ai: AIModel
    /// The provider being edited, or nil when adding one.
    let existing: BYOKProvider?
    var form: BYOKProviderForm {
        didSet {
            // Once saving was tried, the message follows the fields.
            if hasTriedSaving {
                problem = validateBYOKProviderForm(form, existing: existing)
            }
        }
    }
    /// Why the provider can't be saved, after trying.
    private(set) var problem: String?
    private var hasTriedSaving = false
    /// Whether the provider was saved: the sheet is closing, and another
    /// click on its button does nothing.
    private(set) var hasSaved = false
    /// A new provider's ID, the same however often saving is tried, so it
    /// can never be added twice.
    @ObservationIgnored private let newProviderID = UUID().uuidString.lowercased()

    init(ai: AIModel, existing: BYOKProvider?) {
        self.ai = ai
        self.existing = existing
        form = BYOKProviderForm(editing: existing)
    }

    var isEditing: Bool {
        existing != nil
    }

    var title: String {
        isEditing ? "Edit Provider" : "Add Provider"
    }

    var saveTitle: String {
        isEditing ? "Save" : "Add"
    }

    /// Whether the secret field keeps the stored secret when left empty:
    /// editing a provider without changing how it authenticates.
    var keepsStoredSecret: Bool {
        !requiresNewBYOKSecret(form.authKind, existing)
    }

    /// Checks the form, setting `problem`; from then on the message follows
    /// the fields.
    @discardableResult
    func validate() -> Bool {
        hasTriedSaving = true
        problem = validateBYOKProviderForm(form, existing: existing)
        return problem == nil
    }

    /// Saves the provider when the form is valid. Errors storing it (the
    /// keychain's) go to `presenter`.
    ///
    /// - Returns: Whether it was saved, so the sheet can close.
    func save(presenter: WindowPresenter?) async -> Bool {
        guard !hasSaved else {
            return true
        }
        guard validate() else {
            return false
        }
        let newProviderID = newProviderID
        let (provider, secret) = makeBYOKProvider(from: form, existing: existing, newID: { newProviderID })
        let ai = ai
        let isNew = existing == nil
        let intent: @MainActor (IntentAnswers) async throws(OperationError) -> Void = { _ throws(OperationError) in
            if isNew {
                try ai.addProvider(provider, secret: secret)
            } else {
                try ai.updateProvider(provider, secret: secret)
            }
        }
        if let presenter {
            hasSaved = await presenter.perform(intent) != nil
        } else {
            do throws(OperationError) {
                try await intent(IntentAnswers())
                hasSaved = true
            } catch {
                hasSaved = false
            }
        }
        return hasSaved
    }

    // MARK: Models

    /// Adds a model from the model sheet.
    func addModel(_ model: BYOKModel) {
        form.models.append(model)
    }

    /// Replaces the model at `index` with the model sheet's.
    func replaceModel(at index: Int, with model: BYOKModel) {
        guard form.models.indices.contains(index) else {
            return
        }
        form.models[index] = model
    }

    /// Removes a model (nothing is saved until the provider is).
    func removeModel(at index: Int) {
        guard form.models.indices.contains(index) else {
            return
        }
        form.models.remove(at: index)
    }

    /// The model sheet's editor for the model at `index`, or for a new one.
    func modelEditor(for index: Int?) -> ModelEditor {
        let model = index.flatMap { form.models.indices.contains($0) ? form.models[$0] : nil }
        return ModelEditor(model: model, otherModelIds: otherBYOKModelIds(form.models, excluding: index))
    }
}

/// The provider sheet's copy.
enum ProviderCopy {
    static func typeTitle(_ type: BYOKProviderType) -> String {
        switch type {
        case .openai: "OpenAI / OpenAI-compatible"
        case .azure: "Azure"
        case .anthropic: "Anthropic"
        }
    }

    /// The provider list's short name for a type.
    static func typeShortTitle(_ type: BYOKProviderType) -> String {
        switch type {
        case .openai: "OpenAI-compatible"
        case .azure: "Azure"
        case .anthropic: "Anthropic"
        }
    }

    /// The Base URL field's placeholder for a type.
    static func baseURLPlaceholder(_ type: BYOKProviderType) -> String {
        switch type {
        case .openai: "https://api.openai.com/v1"
        case .azure: "https://<resource>.openai.azure.com/"
        case .anthropic: "https://api.anthropic.com"
        }
    }

    static func wireApiTitle(_ wireApi: BYOKWireApi) -> String {
        switch wireApi {
        case .completions: "Chat completions (default)"
        case .responses: "Responses (GPT-5 series)"
        }
    }

    static func authTitle(_ kind: BYOKAuthKind) -> String {
        switch kind {
        case .apiKey: "API key"
        case .bearer: "Bearer token"
        case .none: "None"
        }
    }

    /// "1 model", "3 models".
    static func modelCount(_ count: Int) -> String {
        count == 1 ? "1 model" : "\(count) models"
    }

    /// A model row's heading: its name, else its identifier.
    static func modelHeading(_ model: BYOKModel) -> String {
        if !model.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.name
        }
        return model.id.isEmpty ? "Untitled model" : model.id
    }

    /// A model row's detail: its identifier, and its reasoning effort.
    static func modelDetail(_ model: BYOKModel) -> String {
        let id = model.id.isEmpty ? "—" : model.id
        guard let effort = model.reasoningEffort else {
            return id
        }
        return "\(id) · Reasoning: \(formatReasoningEffort(effort))"
    }
}

/// The provider sheet: the provider's fields in a column form, its
/// authentication, and its models as flat rows.
struct ProviderSheet: View {
    static let sheetID = "espalier.settings.aiProvider"

    @State private var editor: ProviderEditor
    @Environment(WindowContext.self) private var context: WindowContext?
    @Environment(\.dismissModal) private var dismiss

    init(editor: ProviderEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        @Bindable var editor = editor
        SheetScaffold(editor.title) {
            Form {
                LabeledContent("Name") {
                    TextField("Name", text: $editor.form.name, prompt: Text("My provider"))
                        .labelsHidden()
                }
                LabeledContent("Type") {
                    CapsulePopUp("Type", selection: $editor.form.type, title: ProviderCopy.typeTitle(editor.form.type)) {
                        for type in BYOKProviderType.allCases {
                            MenuChoice(ProviderCopy.typeTitle(type), value: type)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $editor.form.baseUrl, prompt: Text(ProviderCopy.baseURLPlaceholder(editor.form.type)))
                        .labelsHidden()
                }
                if editor.form.type == .openai {
                    LabeledContent("API Format") {
                        CapsulePopUp("API Format", selection: $editor.form.wireApi, title: ProviderCopy.wireApiTitle(editor.form.wireApi)) {
                            for wireApi in BYOKWireApi.allCases {
                                MenuChoice(ProviderCopy.wireApiTitle(wireApi), value: wireApi)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if editor.form.type == .azure {
                    LabeledContent("Azure API Version") {
                        TextField("Azure API Version", text: $editor.form.azureApiVersion, prompt: Text("2024-10-21"))
                            .labelsHidden()
                    }
                }
                LabeledContent("Request Timeout") {
                    HStack(spacing: Metrics.insetSmall) {
                        TextField("Request Timeout", text: $editor.form.requestTimeoutSeconds, prompt: Text("Default"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: Metrics.SettingsWindow.narrowControlWidth)
                        Text("seconds")
                            .foregroundStyle(.text2)
                        Spacer(minLength: 0)
                    }
                }
                LabeledContent("Authentication") {
                    CapsulePopUp("Authentication", selection: $editor.form.authKind, title: ProviderCopy.authTitle(editor.form.authKind)) {
                        for kind in BYOKAuthKind.allCases {
                            MenuChoice(ProviderCopy.authTitle(kind), value: kind)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if editor.form.authKind == .none {
                    LabeledContent {
                        SettingsNote("No credentials will be sent with requests to this provider.")
                    } label: {
                        EmptyView()
                    }
                } else {
                    let secretLabel = editor.form.authKind == .bearer ? "Bearer Token" : "API Key"
                    LabeledContent(secretLabel) {
                        SecureField(secretLabel, text: $editor.form.secret, prompt: Text(editor.keepsStoredSecret ? "Unchanged" : "Required"))
                            .labelsHidden()
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Models")
                    .padding(.bottom, Metrics.SettingsWindow.sectionLabelBottom)
                SettingsNote("Tell Espalier which models this provider offers. Each one appears in the model pickers for AI features.")
                    .padding(.bottom, Metrics.SettingsWindow.descriptionSpacing)
                if editor.form.models.isEmpty {
                    Hairline()
                    SettingsMessageRow {
                        SettingsNote("No models yet. Add at least one to use this provider.")
                    }
                }
                ForEach(Array(editor.form.models.enumerated()), id: \.offset) { index, model in
                    Hairline()
                    ModelRow(model: model, edit: { editModel(at: index) }, remove: { editor.removeModel(at: index) })
                }
                Hairline()
                SettingsButtonRow {
                    Button("Add Model…") {
                        editModel(at: nil)
                    }
                    .settingsButton()
                }
            }

            if let problem = editor.problem {
                FieldMessage(problem, kind: .error)
            }
        } buttons: {
            SheetButtons(editor.saveTitle, cancel: { dismiss() }) {
                let presenter = context?.presenter
                Task {
                    if await editor.save(presenter: presenter) {
                        dismiss()
                    }
                }
            }
        }
    }

    /// Opens the model sheet over this one, for the model at `index` or a
    /// new one.
    private func editModel(at index: Int?) {
        guard let modals = context?.modals else {
            return
        }
        let editor = editor
        modals.presentSheet(id: ModelSheet.sheetID) {
            ModelSheet(editor: editor.modelEditor(for: index)) { model in
                if let index {
                    editor.replaceModel(at: index, with: model)
                } else {
                    editor.addModel(model)
                }
            }
        }
    }
}

/// One of the provider sheet's models: its name, its identifier and
/// reasoning effort, and its actions.
struct ModelRow: View {
    let model: BYOKModel
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.SettingsWindow.rowSpacing) {
            SettingsRowText(title: ProviderCopy.modelHeading(model), description: ProviderCopy.modelDetail(model))
                .accessibilityElement(children: .combine)
            RowActionsMenu("Actions for \(ProviderCopy.modelHeading(model))") { [edit, remove] in
                MenuAction("Edit…", action: edit)
                MenuAction("Remove", role: .destructive, action: remove)
            }
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
        .contentShape(Rectangle())
        .contextMenuCard { [edit, remove] in
            MenuAction("Edit…", action: edit)
            MenuAction("Remove", role: .destructive, action: remove)
        }
    }
}
