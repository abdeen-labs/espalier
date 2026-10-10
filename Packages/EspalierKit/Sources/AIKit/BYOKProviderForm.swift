// Ported from desktop/app/src/ui/copilot/edit-byok-provider-dialog.tsx and edit-byok-model-dialog.tsx
//
// The provider and model forms' validation and the values they save, as pure
// functions the settings UI calls.

import EspalierSupport
import Foundation

// MARK: Providers

/// The provider form's fields as the user entered them.
///
/// Printing or dumping a form never shows the secret.
public struct BYOKProviderForm: Sendable, Hashable {
    public var name: String
    public var type: BYOKProviderType
    public var baseUrl: String
    /// Saved for the `openai` type only.
    public var wireApi: BYOKWireApi
    /// Saved for the `azure` type only, when it isn't blank.
    public var azureApiVersion: String
    public var authKind: BYOKAuthKind
    /// The secret as entered, saved trimmed. Blank while editing means "do
    /// not change the stored secret".
    public var secret: String
    /// The request timeout in seconds, as typed. Blank means the default.
    public var requestTimeoutSeconds: String
    public var models: [BYOKModel]

    /// The form for adding a provider, or for editing `provider`, with
    /// these defaults: OpenAI, Chat Completions, an API key.
    public init(editing provider: BYOKProvider? = nil) {
        name = provider?.name ?? ""
        type = provider?.type ?? .openai
        baseUrl = provider?.baseUrl ?? ""
        wireApi = provider?.wireApi ?? .completions
        azureApiVersion = provider?.azureApiVersion ?? ""
        authKind = provider?.authKind ?? .apiKey
        secret = ""
        // `String(provider.requestTimeoutSeconds)`.
        requestTimeoutSeconds = provider?.requestTimeoutSeconds.map(JS.numberToString) ?? ""
        models = provider?.models ?? []
    }
}

extension BYOKProviderForm: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "BYOKProviderForm(name: \(name.debugDescription), type: \(type), baseUrl: \(baseUrl.debugDescription), "
            + "authKind: \(authKind), secret: \(secret.isEmpty ? "<empty>" : "<redacted>"), models: \(models.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

/// What saving the provider form does to the provider's stored secret.
public enum BYOKSecretChange: Sendable, Hashable {
    /// Leave the stored secret alone: editing a provider, nothing typed.
    case keep
    /// Store no secret, removing any stored one: the provider uses no
    /// credentials, or a new provider was given none.
    case remove
    /// Store this secret.
    case set(String)
}

extension BYOKSecretChange: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .keep: "keep"
        case .remove: "remove"
        case .set: "set(<redacted>)"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

/// Checks the provider form before saving: the first problem, as the
/// message to show, or `nil` when the form can be saved.
///
/// - Parameter existing: The provider being edited, or `nil` when adding
///   one.
public func validateBYOKProviderForm(_ form: BYOKProviderForm, existing: BYOKProvider?) -> String? {
    if JSCompat.trim(form.name).isEmpty {
        return "Enter a name."
    }

    let trimmedUrl = JSCompat.trim(form.baseUrl)
    if trimmedUrl.isEmpty {
        return "Enter a base URL."
    }
    if !isValidBYOKBaseUrl(trimmedUrl) {
        return "Base URL must be an https URL, or an http URL pointing at the local machine."
    }

    let modelIds = form.models.map { JSCompat.trim($0.id) }.filter { !$0.isEmpty }
    if modelIds.isEmpty {
        return "Add at least one model."
    }

    // IDs are compared by code units, as JavaScript's `Set` compares them.
    var ids = Set<ExactString>()
    for id in modelIds where !ids.insert(ExactString(id)).inserted {
        return "More than one model uses the identifier \u{201C}\(id)\u{201D}."
    }

    if JSCompat.trim(form.secret).isEmpty, requiresNewBYOKSecret(form.authKind, existing) {
        return form.authKind == .bearer ? "Enter a bearer token." : "Enter an API key."
    }

    let trimmedTimeout = JSCompat.trim(form.requestTimeoutSeconds)
    if !trimmedTimeout.isEmpty, !isValidBYOKRequestTimeout(JS.number(trimmedTimeout)) {
        return "Request timeout must be a positive number of seconds."
    }

    return nil
}

/// The provider to save from a form that passed `validateBYOKProviderForm`,
/// and what to do with its secret.
///
/// Text fields and the secret are trimmed; models without an ID are
/// dropped, and a model without a name is named after its ID; the API
/// format is kept for OpenAI providers and the API version (when not blank)
/// for Azure ones; the timeout is read as JavaScript's `Number` reads it.
///
/// - Parameters:
///   - existing: The provider being edited, whose ID is kept, or `nil` when
///     adding one.
///   - newID: Makes the ID of a new provider, a lowercase UUID.
public func makeBYOKProvider(
    from form: BYOKProviderForm,
    existing: BYOKProvider?,
    newID: () -> String = { UUID().uuidString.lowercased() }
) -> (provider: BYOKProvider, secret: BYOKSecretChange) {
    let models = form.models.filter { !JSCompat.trim($0.id).isEmpty }.map { model in
        let id = JSCompat.trim(model.id)
        let name = JSCompat.trim(model.name)
        return BYOKModel(id: id, name: name.isEmpty ? id : name, reasoningEffort: model.reasoningEffort)
    }
    let azureApiVersion = JSCompat.trim(form.azureApiVersion)
    let timeout = JSCompat.trim(form.requestTimeoutSeconds)
    let typedSecret = JSCompat.trim(form.secret)

    let provider = BYOKProvider(
        id: existing?.id ?? newID(),
        name: JSCompat.trim(form.name),
        type: form.type,
        baseUrl: JSCompat.trim(form.baseUrl),
        wireApi: form.type == .openai ? form.wireApi : nil,
        azureApiVersion: form.type == .azure && !azureApiVersion.isEmpty ? azureApiVersion : nil,
        authKind: form.authKind,
        requestTimeoutSeconds: timeout.isEmpty ? nil : JS.number(timeout),
        models: models
    )

    // Distinguish "the user typed a new secret" from "leave it alone".
    let secret: BYOKSecretChange =
        if form.authKind == .none {
            .remove
        } else if !typedSecret.isEmpty {
            .set(typedSecret)
        } else if existing == nil {
            .remove
        } else {
            .keep
        }
    return (provider, secret)
}

// MARK: Models

/// The model form's fields as the user entered them; a `nil` effort leaves
/// the choice to the provider.
public struct BYOKModelForm: Sendable, Hashable {
    /// The model identifier, as the provider expects it.
    public var id: String
    /// The display name.
    public var name: String
    public var reasoningEffort: ReasoningEffort?

    /// The form for adding a model, or for editing `model`.
    public init(editing model: BYOKModel? = nil) {
        id = model?.id ?? ""
        name = model?.name ?? ""
        reasoningEffort = model?.reasoningEffort
    }
}

/// The identifiers a model form must not reuse: the trimmed, non-empty IDs
/// of the provider form's other models.
///
/// - Parameter index: The model being edited, or `nil` when adding one.
public func otherBYOKModelIds(_ models: [BYOKModel], excluding index: Int?) -> [String] {
    models.enumerated()
        .filter { $0.offset != index }
        .map { JSCompat.trim($0.element.id) }
        .filter { !$0.isEmpty }
}

/// Checks the model form before saving: the problem, as the message to
/// show, or `nil` when the form can be saved.
public func validateBYOKModelForm(_ form: BYOKModelForm, otherModelIds: [String]) -> String? {
    let id = JSCompat.trim(form.id)
    if id.isEmpty {
        return "Enter a model identifier."
    }
    if otherModelIds.contains(where: { JSCompat.strictEquals($0, id) }) {
        return "Another model already uses the identifier \u{201C}\(id)\u{201D}."
    }
    return nil
}

/// The model to save from a form that passed `validateBYOKModelForm`:
/// trimmed, and named after its identifier when the name is blank.
public func makeBYOKModel(from form: BYOKModelForm) -> BYOKModel {
    let id = JSCompat.trim(form.id)
    let name = JSCompat.trim(form.name)
    return BYOKModel(id: id, name: name.isEmpty ? id : name, reasoningEffort: form.reasoningEffort)
}
