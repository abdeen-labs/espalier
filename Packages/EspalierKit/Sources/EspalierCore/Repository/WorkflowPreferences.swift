// Ported from desktop/app/src/models/workflow-preferences.ts

/// Which repository a fork contributes to.
public enum ForkContributionTarget: String, Codable, Sendable, Hashable, CaseIterable {
    /// The repository it was forked from (the default).
    case parent
    /// The fork itself (stored as `"self"`).
    case fork = "self"
}

/// Collection of configurable settings regarding how the user may work with a repository.
public struct WorkflowPreferences: Codable, Sendable, Hashable {
    /// What repo does the user want to contribute to with this fork?
    ///
    /// `nil` when the user never chose; `getForkContributionTarget` reads it
    /// as `.parent`.
    public var forkContributionTarget: ForkContributionTarget?

    public init(forkContributionTarget: ForkContributionTarget? = nil) {
        self.forkContributionTarget = forkContributionTarget
    }

    private enum CodingKeys: String, CodingKey {
        case forkContributionTarget
    }

    /// Decodes leniently: an unknown target reads as no choice.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forkContributionTarget = (try? container.decodeIfPresent(ForkContributionTarget.self, forKey: .forkContributionTarget)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(forkContributionTarget, forKey: .forkContributionTarget)
    }
}
