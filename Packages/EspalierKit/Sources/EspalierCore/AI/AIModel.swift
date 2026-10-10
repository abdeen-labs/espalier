// Ported from desktop/app/src/lib/stores/app-store.ts
//
// Bring-your-own-key providers only. Selections are global, per feature.

import AIKit
import EspalierSupport
import Foundation
import Observation
import os

private let logger = Log.logger(category: "ai")

/// A model a feature can use: a provider's model, and the key that selects
/// it.
public struct AIModelChoice: Sendable, Hashable, Identifiable {
    /// The selection key (`encodeModelKey`), what `AIModel.select(model:for:)`
    /// takes.
    public let key: String
    public let provider: BYOKProvider
    public let model: BYOKModel

    public var id: String {
        key
    }
}

/// What to ask before removing a provider (`AIModel.removalConfirmation(for:)`).
public struct AIProviderRemovalConfirmation: Sendable, Hashable {
    public let title: String
    public let message: String
    /// The destructive button that removes the provider.
    public let confirmButton: String
}

/// first: the sparkle's states and "Resolve with AI"'s gates.
public enum AIFeatureStatus: Sendable, Equatable {
    /// AI features are turned off in Settings: nothing is offered.
    case disabled
    /// No provider with a model is configured: the setup popover.
    case needsProvider
    /// Several models are configured and none is chosen for the feature:
    /// the "Choose a model" popover (`AIModel.availableModels`). There is
    /// never a silent fallback to another model.
    case needsModelChoice
    /// The feature's first request to this provider: show the disclosure
    /// and record the consent (`AIModel.recordConsent(_:)`).
    case needsConsent(AIDataDisclosure)
    /// Ready, with this model.
    case ready(ResolvedModelSelection)
}

/// The AI providers, which model each feature uses, and the consents to
/// send data to them.
///
/// Providers are stored in `copilot-byok-providers`, their secrets in the
/// keychain; selections in `ai-model-selections` (a JSON object from
/// feature to model key); consents in `ai-data-consents`.
/// The AI off switch is `preferences.aiFeaturesEnabled`: while it's off,
/// every feature reports `.disabled` and no request is made.
@MainActor @Observable
public final class AIModel {
    /// The configured providers, in the order they were added.
    public internal(set) var providers: [BYOKProvider] = []
    /// The model each feature uses, as model keys. Only keys naming a
    /// configured provider and model are kept.
    public internal(set) var selections: AIModelSelections = [:]
    /// The consents given (`AIDataDisclosure.consentIdentifier`s).
    public internal(set) var consents: Set<String> = []

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: PreferenceStore
    @ObservationIgnored private let consentStore: AIConsentStore

    init(environment: AppEnvironment) {
        self.environment = environment
        store = PreferenceStore(environment.defaults.defaults)
        consentStore = AIConsentStore(store: store)
        providers = loadBYOKProviders(from: storedProvidersData())
        // A selection naming a deleted provider or model is dropped when
        // providers change; one left over from before (a provider dropped as
        // invalid when loading) is dropped here, in memory.
        selections = scrubModelSelections(loadSelections(), providers: providers)
        consents = consentStore.load()
    }

    func attach(to app: AppModel) {
        self.app = app
    }

    /// Launch work: follow the AI off switch.
    func applicationDidLaunch() {
        observeOffSwitch()
    }

    // MARK: The off switch

    /// Whether AI features are on (Settings ▸ AI, `preferences.aiFeaturesEnabled`).
    public var isEnabled: Bool {
        app?.preferences.aiFeaturesEnabled ?? true
    }

    /// Turning AI off stops what's running: generations, conflict rounds,
    /// and their results.
    private func observeOffSwitch() {
        guard let app else {
            return
        }
        withObservationTracking {
            _ = app.preferences.aiFeaturesEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let app = self.app else {
                    return
                }
                if !app.preferences.aiFeaturesEnabled {
                    for model in app.models.values {
                        model.ai.aiFeaturesWereTurnedOff()
                    }
                }
                self.observeOffSwitch()
            }
        }
    }

    // MARK: Status

    /// Whether `feature` can make its request now, or what's missing.
    public func status(for feature: AIFeature) -> AIFeatureStatus {
        guard isEnabled else {
            return .disabled
        }
        guard hasModels else {
            return .needsProvider
        }
        guard let resolved = resolvedModel(for: feature) else {
            return .needsModelChoice
        }
        let disclosure = getAIDataDisclosure(for: feature, provider: resolved.provider)
        guard consents.contains(disclosure.consentIdentifier) else {
            return .needsConsent(disclosure)
        }
        return .ready(resolved)
    }

    /// Whether any provider has a model.
    public var hasModels: Bool {
        providers.contains { !$0.models.isEmpty }
    }

    /// The model `feature` uses: its selection, or the only model there is.
    /// Nil when there is no model, or several and none is selected.
    public func resolvedModel(for feature: AIFeature) -> ResolvedModelSelection? {
        resolveModelSelection(selections[feature], providers: providers)
    }

    /// The model name and reasoning effort `feature` would use, for headers
    /// ("<model> · <Effort>").
    public func modelDisplay(for feature: AIFeature) -> ConflictResolutionModelDisplay? {
        resolvedModel(for: feature).map(Self.display)
    }

    static func display(_ selection: ResolvedModelSelection) -> ConflictResolutionModelDisplay {
        ConflictResolutionModelDisplay(modelName: selection.model.name, reasoningEffort: selection.model.reasoningEffort)
    }

    // MARK: Models

    /// Every configured model, provider by provider, for the model pickers.
    public var availableModels: [AIModelChoice] {
        providers.flatMap { provider in
            provider.models.map { model in
                AIModelChoice(
                    key: encodeModelKey(AIModelKey(providerId: provider.id, modelId: model.id)),
                    provider: provider,
                    model: model
                )
            }
        }
    }

    /// Selects the model a feature uses (a key from `availableModels`), or
    /// clears the selection. A key naming no configured model changes
    /// nothing.
    public func select(model key: String?, for feature: AIFeature) {
        var updated = selections
        if let key {
            guard !scrubModelSelections([feature: key], providers: providers).isEmpty else {
                logger.error("Ignored a model selection that names no configured model")
                return
            }
            updated[feature] = key
        } else {
            updated[feature] = nil
        }
        setSelections(updated)
    }

    private func setSelections(_ updated: AIModelSelections) {
        guard !selectionsEqual(updated, selections) else {
            return
        }
        selections = updated
        saveSelections()
    }

    /// Drops selections naming a provider or model that no longer exists.
    private func scrubSelections() {
        setSelections(scrubModelSelections(selections, providers: providers))
    }

    // MARK: Providers

    /// Adds a provider, storing its secret in the keychain first so a
    /// keychain failure doesn't leave a provider without its credentials. A
    /// provider whose ID is already configured is updated instead.
    ///
    /// - Parameter secret: What `makeBYOKProvider(from:existing:)` says to do
    ///   with the secret; only `.set` stores one for a new provider.
    public func addProvider(_ provider: BYOKProvider, secret: BYOKSecretChange = .keep) throws(OperationError) {
        if providers.contains(where: { JSCompat.strictEquals($0.id, provider.id) }) {
            try updateProvider(provider, secret: secret)
            return
        }
        let updated = providers + [provider]
        let data = try encode(updated, provider)
        if case .set(let value) = secret, !value.isEmpty {
            try setSecret(value, for: provider)
        }
        commit(updated, data: data)
        logger.info("Added an AI provider")
    }

    /// Replaces a provider (matched by ID), applying the keychain change
    /// first: `.keep` leaves the stored secret, `.remove` deletes it, and
    /// `.set` stores a new one. Then drops selections of models it no longer
    /// has. An unknown ID is added.
    /// Consents for a host it no longer uses are dropped.
    public func updateProvider(_ provider: BYOKProvider, secret: BYOKSecretChange = .keep) throws(OperationError) {
        guard let index = providers.firstIndex(where: { JSCompat.strictEquals($0.id, provider.id) }) else {
            try addProvider(provider, secret: secret)
            return
        }
        let previous = providers[index]
        var updated = providers
        updated[index] = provider
        let data = try encode(updated, provider)
        switch secret {
        case .keep:
            break
        case .remove:
            try deleteSecret(for: provider)
        case .set(let value):
            if !value.isEmpty {
                try setSecret(value, for: provider)
            }
        }
        commit(updated, data: data)
        scrubSelections()
        let current = Set(AIConsentStore.consentIdentifiers(for: provider))
        revokeConsents(AIConsentStore.consentIdentifiers(for: previous).filter { !current.contains($0) })
        logger.info("Updated an AI provider")
    }

    /// Removes a provider: its secret first (on failure the provider stays,
    /// so removing can be tried again), then the provider, the selections of
    /// its models, and the consents to send it data. An unknown ID does
    /// nothing.
    ///
    /// Settings asks first (`removalConfirmation(for:)`).
    ///
    /// - Throws: A keychain failure.
    public func removeProvider(id: String) throws(OperationError) {
        guard let provider = providers.first(where: { JSCompat.strictEquals($0.id, id) }) else {
            return
        }
        let updated = providers.filter { !JSCompat.strictEquals($0.id, id) }
        let data = try encode(updated, provider)
        try deleteSecret(for: provider)
        commit(updated, data: data)
        scrubSelections()
        revokeConsents(forProvider: provider)
        logger.info("Removed an AI provider")
    }

    /// What Settings asks before `removeProvider(id:)`: the confirm button is
    /// destructive.
    public static func removalConfirmation(for provider: BYOKProvider) -> AIProviderRemovalConfirmation {
        let message = switch provider.authKind {
        case .apiKey: "Its API key will also be removed from your keychain."
        case .bearer: "Its bearer token will also be removed from your keychain."
        case .none: "Models that use it will no longer be available."
        }
        return AIProviderRemovalConfirmation(title: "Remove \"\(provider.name)\"?", message: message, confirmButton: "Remove")
    }

    /// Encodes the providers before anything changes, so a failure leaves
    /// the stored value, the keychain, and memory as they were.
    private func encode(_ updated: [BYOKProvider], _ provider: BYOKProvider) throws(OperationError) -> Data? {
        do {
            return try saveBYOKProviders(updated)
        } catch {
            throw OperationError(
                .other("Couldn't save \"\(provider.name)\". \(aiErrorDescription(error))"),
                operation: .updateAIProviders,
                underlying: error
            )
        }
    }

    private func commit(_ updated: [BYOKProvider], data: Data?) {
        if let data {
            store.setString(PreferenceKey.byokProviders, String(decoding: data, as: UTF8.self))
        } else {
            store.remove(PreferenceKey.byokProviders)
        }
        providers = updated
    }

    private func setSecret(_ secret: String, for provider: BYOKProvider) throws(OperationError) {
        do {
            try environment.secrets.setSecret(secret, service: BYOKSecretService, account: provider.id)
        } catch {
            throw OperationError(
                .other("Couldn't save the credential for \"\(provider.name)\" in your keychain. \(aiErrorDescription(error))"),
                operation: .updateAIProviders,
                underlying: error
            )
        }
    }

    private func deleteSecret(for provider: BYOKProvider) throws(OperationError) {
        do {
            try environment.secrets.deleteSecret(service: BYOKSecretService, account: provider.id)
        } catch {
            throw OperationError(
                .other("Couldn't remove the credential for \"\(provider.name)\" from your keychain. \(aiErrorDescription(error))"),
                operation: .updateAIProviders,
                underlying: error
            )
        }
    }

    // MARK: Consent

    /// What `feature`'s first request to its provider would send, and where;
    /// nil when no model resolves for it.
    public func disclosure(for feature: AIFeature) -> AIDataDisclosure? {
        resolvedModel(for: feature).map { getAIDataDisclosure(for: feature, provider: $0.provider) }
    }

    /// Records the user's consent to a disclosure.
    public func recordConsent(_ consentIdentifier: String) {
        guard !consents.contains(consentIdentifier) else {
            return
        }
        consents.insert(consentIdentifier)
        consentStore.save(consents)
    }

    /// Withdraws a consent: the next request asks again.
    public func revokeConsent(_ consentIdentifier: String) {
        revokeConsents([consentIdentifier])
    }

    /// Withdraws every consent to send data to `provider`.
    public func revokeConsents(forProvider provider: BYOKProvider) {
        revokeConsents(AIConsentStore.consentIdentifiers(for: provider))
    }

    /// Withdraws every consent.
    public func revokeAllConsents() {
        revokeConsents(Array(consents))
    }

    private func revokeConsents(_ identifiers: [String]) {
        let remaining = consents.subtracting(identifiers)
        guard remaining != consents else {
            return
        }
        consents = remaining
        consentStore.save(remaining)
    }

    /// The consents given for the configured providers, provider by
    /// provider, for Settings ▸ AI.
    public var grantedConsents: [AIGrantedConsent] {
        providers.flatMap { provider in
            AIFeature.allCases.compactMap { feature in
                let disclosure = getAIDataDisclosure(for: feature, provider: provider)
                return consents.contains(disclosure.consentIdentifier)
                    ? AIGrantedConsent(provider: provider, disclosure: disclosure)
                    : nil
            }
        }
    }

    // MARK: Gates for the repository features

    /// The model `feature` uses, or why there's none.
    func requireModel(for feature: AIFeature, operation: OperationKind, repositoryID: RepositoryID?) throws(OperationError) -> ResolvedModelSelection {
        func fail(_ failure: AIFailure) -> OperationError {
            OperationError(
                .ai(failure),
                operation: operation,
                repositoryID: repositoryID,
                recoveries: aiRecoveries(for: failure, underlying: nil)
            )
        }
        guard isEnabled else {
            throw fail(.disabled)
        }
        guard hasModels else {
            throw fail(.noProvider)
        }
        guard let resolved = resolvedModel(for: feature) else {
            throw fail(.modelSelectionRequired)
        }
        return resolved
    }

    /// Throws `consentRequired` until the user has agreed to send
    /// `feature`'s data to `selection`'s provider.
    func requireConsent(
        for feature: AIFeature,
        _ selection: ResolvedModelSelection,
        operation: OperationKind,
        repositoryID: RepositoryID?
    ) throws(OperationError) {
        let disclosure = getAIDataDisclosure(for: feature, provider: selection.provider)
        guard consents.contains(disclosure.consentIdentifier) else {
            throw OperationError(.ai(.consentRequired(provider: selection.provider.name)), operation: operation, repositoryID: repositoryID)
        }
    }

    /// Whether `selection`'s provider and model are still configured as they
    /// were, and still the ones `feature` resolves to.
    func isCurrent(_ selection: ResolvedModelSelection, for feature: AIFeature) -> Bool {
        resolvedModel(for: feature) == selection
    }

    // MARK: Storage

    private func storedProvidersData() -> Data? {
        let value = store.defaults.object(forKey: PreferenceKey.byokProviders)
        if let string = value as? String {
            return Data(string.utf8)
        }
        return value as? Data
    }

    /// `ai-model-selections`: a JSON object from feature to model key.
    /// Unknown features and values that aren't strings are ignored.
    private func loadSelections() -> AIModelSelections {
        guard let string = store.getString(PreferenceKey.aiModelSelections),
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        else {
            return [:]
        }
        var selections: AIModelSelections = [:]
        for feature in AIFeature.allCases {
            if let key = object[feature.rawValue] as? String {
                selections[feature] = key
            }
        }
        return selections
    }

    /// Writes the selections, removing the key when there are none.
    private func saveSelections() {
        guard !selections.isEmpty else {
            store.remove(PreferenceKey.aiModelSelections)
            return
        }
        let object = Dictionary(uniqueKeysWithValues: selections.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object) else {
            return
        }
        store.setString(PreferenceKey.aiModelSelections, String(decoding: data, as: UTF8.self))
    }
}

/// Whether two selections are the same, keys compared by code units.
private func selectionsEqual(_ lhs: AIModelSelections, _ rhs: AIModelSelections) -> Bool {
    lhs.count == rhs.count && lhs.allSatisfy { feature, key in
        rhs[feature].map { JSCompat.strictEquals($0, key) } ?? false
    }
}

/// An error's description for messages: its `LocalizedError` text, else
/// what it prints (the keychain's errors describe themselves).
func aiErrorDescription(_ error: any Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription {
        return description
    }
    return String(describing: error)
}
