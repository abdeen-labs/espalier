// Ported from desktop/app/src/lib/copilot/conflict-resolution-model.ts

/// The model name and reasoning effort to display for conflict resolution.
public struct ConflictResolutionModelDisplay: Sendable, Hashable {
    public var modelName: String
    public var reasoningEffort: ReasoningEffort?

    public init(modelName: String, reasoningEffort: ReasoningEffort?) {
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
    }
}

/// Resolves the stored `conflict-resolution` selection into the model name
/// and reasoning effort that resolution will actually use, so the progress
/// view's header matches. Mirrors `resolveAIModelRequest`: names are shown
/// verbatim (they're user-provided) and the effort passes through.
///
/// `nil` when no model resolves (see `resolveModelSelection`).
public func getConflictResolutionModelDisplay(
    _ selection: String?,
    providers: [BYOKProvider]
) -> ConflictResolutionModelDisplay? {
    guard let resolved = resolveModelSelection(selection, providers: providers) else {
        return nil
    }
    return ConflictResolutionModelDisplay(
        modelName: resolved.model.name,
        reasoningEffort: resolved.model.reasoningEffort
    )
}
