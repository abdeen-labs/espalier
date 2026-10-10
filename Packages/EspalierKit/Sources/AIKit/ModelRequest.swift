// Ported from desktop/app/src/lib/stores/app-store.ts and copilot-store.ts

import EspalierSupport
import Foundation

/// The AI features that support per-feature model selection.
public enum AIFeature: String, Sendable, Hashable, Codable, CodingKeyRepresentable, CaseIterable {
    case commitMessageGeneration = "commit-message-generation"
    case conflictResolution = "conflict-resolution"
}

/// Per-feature model selections, as `encodeModelKey` strings. An absent key
/// means no model has been chosen for that feature.
public typealias AIModelSelections = [AIFeature: String]

/// A model chosen for a feature, and its provider.
public struct ResolvedModelSelection: Sendable, Hashable {
    public var provider: BYOKProvider
    public var model: BYOKModel

    public init(provider: BYOKProvider, model: BYOKModel) {
        self.provider = provider
        self.model = model
    }
}

/// Resolves a stored selection to a configured provider and model.
///
/// A selection naming a provider and model that exist resolves to them.
/// Otherwise, when exactly one model is configured across all providers, it
/// is used; with more than one there is no implicit choice and the result is
/// `nil`, so the app asks the user to pick.
///
/// There is no default model: silently switching to another provider could
/// send the repository's code to a service the user never chose for this
/// feature.
public func resolveModelSelection(_ selection: String?, providers: [BYOKProvider]) -> ResolvedModelSelection? {
    if let selection, let key = parseModelKey(selection),
       let provider = providers.first(where: { JSCompat.strictEquals($0.id, key.providerId) }),
       let model = provider.models.first(where: { JSCompat.strictEquals($0.id, key.modelId) })
    {
        return ResolvedModelSelection(provider: provider, model: model)
    }

    let all = providers.flatMap { provider in provider.models.map { (provider, $0) } }
    guard all.count == 1, let (provider, model) = all.first else {
        return nil
    }
    return ResolvedModelSelection(provider: provider, model: model)
}

/// Drops selections that don't name a configured provider and model
/// (deleted providers or models, `copilot:` keys, and bare model IDs). Call
/// it after providers change and after loading selections.
///
/// IDs are compared by code units, as JavaScript's `===` compares them.
public func scrubModelSelections(_ selections: AIModelSelections, providers: [BYOKProvider]) -> AIModelSelections {
    selections.filter { _, raw in
        guard let key = parseModelKey(raw),
              let provider = providers.first(where: { JSCompat.strictEquals($0.id, key.providerId) })
        else {
            return false
        }
        return provider.models.contains { JSCompat.strictEquals($0.id, key.modelId) }
    }
}

/// A resolved request for one feature: the model, its provider (with the
/// credential read from the keychain), and the per-request settings.
public struct AIModelRequest: Sendable, Hashable {
    /// Model ID sent to the provider.
    public var modelId: String
    public var provider: AIProviderConfiguration
    /// Reasoning effort to send. When `nil`, none is sent.
    public var reasoningEffort: ReasoningEffort?
    /// Per-request timeout. When `nil`, the feature's default is used.
    /// Anything longer than `MaxAIRequestTimeoutSeconds` is clamped to it.
    public var timeout: Duration?

    public init(
        modelId: String,
        provider: AIProviderConfiguration,
        reasoningEffort: ReasoningEffort? = nil,
        timeout: Duration? = nil
    ) {
        self.modelId = modelId
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
    }
}

/// The selected model can't be used because its credential is missing or
/// unreadable. The message is shown to the user.
public struct AIModelRequestError: Error, LocalizedError, Sendable, Hashable {
    public let message: String

    public var errorDescription: String? { message }
}

/// Resolves a stored model selection into an `AIModelRequest`, reading the
/// provider's secret from the keychain at call time. Returns `nil` when
/// `resolveModelSelection` finds no model.
///
/// Throws `AIModelRequestError` when the provider needs a credential that
/// can't be read or isn't stored.
public func resolveAIModelRequest(
    selection: String?,
    providers: [BYOKProvider],
    secretStore: any SecretStore = KeychainSecretStore()
) async throws -> AIModelRequest? {
    guard let resolved = resolveModelSelection(selection, providers: providers) else {
        return nil
    }
    let provider = resolved.provider
    let model = resolved.model

    var secret: String?
    if provider.authKind != .none {
        do {
            secret = try await getBYOKSecret(provider.id, store: secretStore)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw AIModelRequestError(
                message: "Could not read the credential for the AI provider '\(provider.name)' from the keychain: \(message)"
            )
        }
    }

    let credential: AICredential
    switch provider.authKind {
    case .none:
        credential = .none
    case .apiKey, .bearer:
        guard let secret, !secret.isEmpty else {
            let noun = provider.authKind == .bearer ? "bearer token" : "API key"
            throw AIModelRequestError(
                message: "No \(noun) is saved for the AI provider \u{201C}\(provider.name)\u{201D}. "
                    + "Enter it again in Settings ▸ AI."
            )
        }
        credential = provider.authKind == .bearer ? .bearer(secret) : .apiKey(secret)
    }

    // `requestTimeoutSeconds` in milliseconds, clamped first so the
    // conversion can't overflow. A timeout that isn't a positive finite
    // number (which only code can set) means the default, as it would after
    // saving and loading the provider.
    var timeout: Duration?
    if let seconds = provider.requestTimeoutSeconds, isValidBYOKRequestTimeout(seconds) {
        timeout = .milliseconds(Int64((min(seconds, MaxAIRequestTimeoutSeconds) * 1000).rounded()))
    }

    return AIModelRequest(
        modelId: model.id,
        provider: AIProviderConfiguration(
            name: provider.name,
            type: provider.type,
            baseUrl: provider.baseUrl,
            wireApi: provider.wireApi,
            azureApiVersion: provider.type == .azure ? provider.azureApiVersion : nil,
            credential: credential
        ),
        reasoningEffort: model.reasoningEffort,
        timeout: timeout
    )
}
