// The model a feature uses, from the bring-your-own-key providers. Nothing
// is picked silently: the pop-up shows "None" while several models are
// configured and none is chosen (a selection resolves only when it is valid
// or there is one model).

import AIKit
import EspalierCore
import EspalierSupport
import SwiftUI

/// A feature's model: a row with a pop-up of the configured models, by
/// provider.
struct ModelPicker: View {
    let title: String
    let description: String?
    let feature: AIFeature
    let ai: AIModel

    init(_ title: String, description: String? = nil, feature: AIFeature, ai: AIModel) {
        self.title = title
        self.description = description
        self.feature = feature
        self.ai = ai
    }

    var body: some View {
        SettingsRow(title, description: description, labelsControl: true) {
            CapsulePopUp(title, selection: selection, title: ModelPickerItems.selectedTitle(for: feature, in: ai)) {
                if ModelPickerItems.selectedKey(for: feature, in: ai) == nil {
                    Text("None").tag(String?.none)
                }
                ForEach(ModelPickerItems.groups(in: ai), id: \.provider.id) { group in
                    Section(group.provider.name) {
                        ForEach(group.choices) { choice in
                            Text(ModelPickerItems.title(of: choice.model)).tag(Optional(choice.key))
                        }
                    }
                }
            }
            .settingsControlWidth()
        }
    }

    private var selection: Binding<String?> {
        Binding {
            ModelPickerItems.selectedKey(for: feature, in: ai)
        } set: { key in
            ai.select(model: key, for: feature)
        }
    }
}

/// What the model pop-up lists.
@MainActor
enum ModelPickerItems {
    /// The models, grouped by provider, in the providers' order.
    static func groups(in ai: AIModel) -> [(provider: BYOKProvider, choices: [AIModelChoice])] {
        var groups: [(provider: BYOKProvider, choices: [AIModelChoice])] = []
        for choice in ai.availableModels {
            if let last = groups.indices.last, JSCompat.strictEquals(groups[last].provider.id, choice.provider.id) {
                groups[last].choices.append(choice)
            } else {
                groups.append((choice.provider, [choice]))
            }
        }
        return groups
    }

    /// The key of the model `feature` uses: its selection, or the only
    /// model; nil when several are configured and none is chosen.
    static func selectedKey(for feature: AIFeature, in ai: AIModel) -> String? {
        ai.resolvedModel(for: feature).map { resolved in
            encodeModelKey(AIModelKey(providerId: resolved.provider.id, modelId: resolved.model.id))
        }
    }

    /// The pop-up's title: the model `feature` uses, or "None".
    static func selectedTitle(for feature: AIFeature, in ai: AIModel) -> String {
        ai.resolvedModel(for: feature).map { title(of: $0.model) } ?? "None"
    }

    /// A model's item: its name, with its reasoning effort when it has one
    /// ("GPT-5 (High)").
    static func title(of model: BYOKModel) -> String {
        guard let effort = model.reasoningEffort else {
            return model.name
        }
        return "\(model.name) (\(formatReasoningEffort(effort)))"
    }
}
