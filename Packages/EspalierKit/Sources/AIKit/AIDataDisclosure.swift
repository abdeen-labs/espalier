// Bring-your-own-key providers send data wherever the user points them, so
// before the first request to a provider the app tells the user what will be
// sent and where. AIKit supplies the facts; the app shows them and remembers
// consent by `consentIdentifier`.

import Foundation

/// What a feature sends to a provider, and where.
public struct AIDataDisclosure: Sendable, Hashable {
    public let feature: AIFeature
    /// The provider's name from settings.
    public let providerName: String
    /// Where requests go: the host, with the port when the base URL has one
    /// (`api.openai.com`, `localhost:11434`).
    public let host: String
    /// Whether the host is this Mac (`isLocalBaseUrl`).
    public let isLocal: Bool
    /// What is sent, one item per entry.
    public let sentData: [String]
    /// One sentence introducing `sentData`, naming the provider and host.
    public let summary: String
    /// The feature's disclaimer: results come from AI and need review.
    public let reviewAdvice: String
    /// Identifies what the user agrees to: the feature, the provider, and
    /// where its requests go. Changing the provider's base URL to another
    /// host changes it, so the app asks again.
    public let consentIdentifier: String
}

/// The disclosure for sending a feature's data to a provider.
public func getAIDataDisclosure(for feature: AIFeature, provider: BYOKProvider) -> AIDataDisclosure {
    let components = parseBaseUrl(provider.baseUrl)
    let scheme = components?.scheme?.lowercased() ?? ""
    var host = components?.percentEncodedHost?.lowercased() ?? provider.baseUrl
    if let port = components?.port {
        host += ":\(port)"
    }
    let isLocal = isLocalBaseUrl(provider.baseUrl)

    let purpose: String
    let sentData: [String]
    let advice: String
    switch feature {
    case .commitMessageGeneration:
        purpose = "To generate commit messages"
        sentData = [
            "The diff of the changes being committed",
            "The repository's commit message rules, when it has any",
            "The repository's instructions for AI tools, when it has them",
        ]
        advice = "Review and edit the generated message carefully before use."
    case .conflictResolution:
        purpose = "To resolve conflicts"
        sentData = [
            "The conflicting sections of each conflicted file, with a few lines of surrounding context",
            "The paths of the conflicted files and the branch or commit on each side",
            "Recent commit messages from both sides",
            "The titles and descriptions of related pull requests",
            "The repository's instructions for AI tools, when it has them",
        ]
        advice = "Review the suggested resolutions carefully before applying them to your files."
    }

    let destination =
        isLocal
        ? "\(provider.name), a server on this Mac (\(host))"
        : "\(provider.name) at \(host)"

    return AIDataDisclosure(
        feature: feature,
        providerName: provider.name,
        host: host,
        isLocal: isLocal,
        sentData: sentData,
        summary: "\(purpose), Espalier sends the following to \(destination):",
        reviewAdvice: "This feature is powered by AI, so mistakes are possible. \(advice)",
        consentIdentifier: "\(feature.rawValue)|\(provider.id)|\(scheme)://\(host)"
    )
}
