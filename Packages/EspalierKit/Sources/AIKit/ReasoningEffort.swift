// Ported from desktop/app/src/lib/stores/copilot-store.ts (reasoning effort)

/// How hard a reasoning model thinks before answering.
///
/// Cases are declared from lowest to highest, so they compare in that order.
public enum ReasoningEffort: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case xhigh

    public static func < (lhs: ReasoningEffort, rhs: ReasoningEffort) -> Bool {
        ReasoningEffortOrder.firstIndex(of: lhs)! < ReasoningEffortOrder.firstIndex(of: rhs)!
    }
}

/// Ordered reasoning effort levels from lowest to highest.
public let ReasoningEffortOrder: [ReasoningEffort] = [.low, .medium, .high, .xhigh]

/// Formats a reasoning effort for display, e.g. `xhigh` becomes "Extra high".
public func formatReasoningEffort(_ effort: ReasoningEffort) -> String {
    if effort == .xhigh {
        return "Extra high"
    }
    let raw = effort.rawValue
    return raw.prefix(1).uppercased() + raw.dropFirst()
}

/// Returns the lowest reasoning effort a model supports, or `nil` if the
/// model does not support reasoning effort configuration.
public func getLowestReasoningEffort(_ supportedReasoningEfforts: [ReasoningEffort]?) -> ReasoningEffort? {
    guard let supported = supportedReasoningEfforts, !supported.isEmpty else {
        return nil
    }
    return ReasoningEffortOrder.first { supported.contains($0) }
}

/// Resolves the reasoning effort to send for a model, preferring `preferred`
/// when the model supports it. Falls back to the model's lowest supported
/// effort, or `nil` when the model doesn't support reasoning effort at all
/// (so an unsupported value is never sent to the provider).
public func getSupportedReasoningEffort(
    _ supportedReasoningEfforts: [ReasoningEffort]?,
    preferred: ReasoningEffort
) -> ReasoningEffort? {
    if supportedReasoningEfforts?.contains(preferred) == true {
        return preferred
    }
    return getLowestReasoningEffort(supportedReasoningEfforts)
}
