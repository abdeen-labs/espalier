// Settings ▸ AI. The AI switch (off hides every AI entry point and makes no
// requests), the providers (with the provider and model sheets), the model
// each feature uses and "Always use AI when conflicts are detected", and the
// data consents, each revocable. Removing a provider asks first
// (`AIModel.removalConfirmation(for:)`).

import AIKit
import EspalierCore
import EspalierSupport
import SwiftUI

/// Settings ▸ AI.
public struct AIPane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            AIForm(
                preferences: model.preferences,
                ai: model.ai,
                actions: context.map { AIPaneActions(app: model, presenter: $0.presenter, modals: $0.modals) }
            )
        } else {
            SettingsPanePlaceholder(tab: .ai)
        }
    }
}

/// What the AI pane's buttons do.
@MainActor
struct AIPaneActions {
    let app: AppModel
    let presenter: WindowPresenter
    let modals: ModalPresenter
    /// Asks a question in an alert; whether the first button was chosen.
    /// The Settings window's alert by default; tests answer it.
    var confirm: @MainActor (AlertContent) async -> Bool

    init(app: AppModel, presenter: WindowPresenter, modals: ModalPresenter, confirm: (@MainActor (AlertContent) async -> Bool)? = nil) {
        self.app = app
        self.presenter = presenter
        self.modals = modals
        self.confirm = confirm ?? { content in
            await modals.alert(content).buttonIndex == 0
        }
    }

    /// Opens the provider sheet for a new provider.
    func addProvider() {
        presentProviderSheet(existing: nil)
    }

    /// Opens the provider sheet for `provider`.
    func editProvider(_ provider: BYOKProvider) {
        presentProviderSheet(existing: provider)
    }

    private func presentProviderSheet(existing: BYOKProvider?) {
        let editor = ProviderEditor(ai: app.ai, existing: existing)
        modals.presentSheet(id: ProviderSheet.sheetID) {
            ProviderSheet(editor: editor)
        }
    }

    /// Asks (with the keychain line), then removes the provider, its secret,
    /// its models' selections, and the consents to send it data.
    func removeProvider(_ provider: BYOKProvider) async {
        guard await confirm(Self.removalAlert(for: provider)) else {
            return
        }
        let ai = app.ai
        let id = provider.id
        await presenter.perform { _ throws(OperationError) in
            try ai.removeProvider(id: id)
        }
    }

    /// The removal question, as an alert.
    static func removalAlert(for provider: BYOKProvider) -> AlertContent {
        let confirmation = AIModel.removalConfirmation(for: provider)
        return AlertContent(
            title: confirmation.title,
            message: confirmation.message,
            buttons: [
                AlertContent.Button(confirmation.confirmButton, role: .destructive),
                AlertContent.Button("Cancel", role: .cancel),
            ],
            severity: .critical
        )
    }

    /// Withdraws every consent to send data to `provider`: the next request
    /// asks again.
    func revokeConsents(for provider: BYOKProvider) {
        app.ai.revokeConsents(forProvider: provider)
    }
}

/// The consents given to one provider.
nonisolated struct ProviderConsents: Identifiable, Equatable, Sendable {
    let provider: BYOKProvider
    let consents: [AIGrantedConsent]

    var id: String {
        provider.id
    }

    /// The features, in words ("Commit messages, conflict resolution").
    var featuresTitle: String {
        let titles = consents.map { AIFeatureCopy.title($0.feature) }
        guard let first = titles.first else {
            return ""
        }
        return ([first] + titles.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
    }

    /// Where the requests go ("api.openai.com").
    var host: String {
        consents.first?.disclosure.host ?? ""
    }

    /// The granted consents, grouped by provider, in the providers' order.
    static func group(_ consents: [AIGrantedConsent]) -> [ProviderConsents] {
        var groups: [ProviderConsents] = []
        for consent in consents {
            if let last = groups.last, JSCompat.strictEquals(last.provider.id, consent.provider.id) {
                groups[groups.count - 1] = ProviderConsents(provider: last.provider, consents: last.consents + [consent])
            } else {
                groups.append(ProviderConsents(provider: consent.provider, consents: [consent]))
            }
        }
        return groups
    }
}

/// The features' names.
nonisolated enum AIFeatureCopy {
    static func title(_ feature: AIFeature) -> String {
        switch feature {
        case .commitMessageGeneration: "Commit messages"
        case .conflictResolution: "Conflict resolution"
        }
    }
}

/// The AI pane: the switch, then the providers, the models, and the data
/// shared with them.
struct AIForm: View {
    @Bindable var preferences: Preferences
    let ai: AIModel
    let actions: AIPaneActions?

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsToggleRow(
                    "Use AI features",
                    description: "Generate commit messages and resolve conflicts with models from providers you set up. When off, Espalier shows no AI features and sends nothing to any provider.",
                    isOn: $preferences.aiFeaturesEnabled
                )
            }

            if preferences.aiFeaturesEnabled {
                SettingsSection("Providers") {
                    if ai.providers.isEmpty {
                        SettingsMessageRow {
                            SettingsNote("Add a provider to use your own API keys with OpenAI-compatible endpoints, Azure, Anthropic, or local providers like Ollama.")
                        }
                    }
                    ForEach(ai.providers, id: \.id) { provider in
                        ProviderRow(
                            provider: provider,
                            edit: { actions?.editProvider(provider) },
                            remove: {
                                let actions = actions
                                Task { await actions?.removeProvider(provider) }
                            }
                        )
                    }
                    SettingsButtonRow {
                        Button("Add Provider…") {
                            actions?.addProvider()
                        }
                        .settingsButton()
                    }
                }
                .barTransition()

                SettingsSection("Models") {
                    if ai.hasModels {
                        ModelPicker("Commit messages", feature: .commitMessageGeneration, ai: ai)
                        ModelPicker(
                            "Conflict resolution",
                            description: "Model changes apply to future conflict resolutions.",
                            feature: .conflictResolution,
                            ai: ai
                        )
                    } else {
                        SettingsMessageRow {
                            SettingsNote("Add a provider with at least one model to choose the models AI features use.")
                        }
                    }
                    SettingsToggleRow("Always use AI when conflicts are detected", isOn: $preferences.alwaysUseAIForConflictResolution)
                }
                .barTransition()

                SettingsSection("Data sharing") {
                    SettingsMessageRow {
                        SettingsNote("Espalier sends diffs and file contents only to the providers you choose, and asks before the first request to each one.")
                    }
                    let groups = ProviderConsents.group(ai.grantedConsents)
                    if groups.isEmpty {
                        SettingsMessageRow {
                            SettingsNote("You haven't allowed any provider to receive your data.")
                        }
                    }
                    ForEach(groups) { group in
                        SettingsRow(group.provider.name, description: "\(group.featuresTitle) · \(group.host)") {
                            Button("Revoke") {
                                actions?.revokeConsents(for: group.provider)
                            }
                            .settingsButton()
                            .accessibilityLabel("Revoke \(group.provider.name)")
                        }
                    }
                }
                .barTransition()
            }
        }
        // Turning AI on shows its sections, growing in over 0.22 s (and
        // leaving over 0.15 s).
        .barMotion(preferences.aiFeaturesEnabled)
    }
}

/// One provider: its name, the Local badge, its type and model count, and
/// its actions.
struct ProviderRow: View {
    let provider: BYOKProvider
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.SettingsWindow.rowSpacing) {
            VStack(alignment: .leading, spacing: Metrics.SettingsWindow.descriptionSpacing) {
                HStack(spacing: Metrics.insetSmall) {
                    Text(provider.name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(.text)
                    if isLocalBaseUrl(provider.baseUrl) {
                        LocalBadge()
                    }
                }
                Text("\(ProviderCopy.typeShortTitle(provider.type)) · \(ProviderCopy.modelCount(provider.models.count))")
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            RowActionsMenu("Actions for \(provider.name)") { [edit, remove] in
                MenuAction("Edit…", action: edit)
                MenuAction("Remove…", role: .destructive, action: remove)
            }
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
        .contentShape(Rectangle())
        .contextMenuCard { [edit, remove] in
            MenuAction("Edit…", action: edit)
            MenuAction("Remove…", role: .destructive, action: remove)
        }
    }
}
