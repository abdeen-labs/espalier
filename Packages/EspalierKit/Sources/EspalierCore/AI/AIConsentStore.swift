// With bring-your-own-key providers a feature's data goes wherever the user
// points it, so the user is asked before a feature's first request to each
// provider, shown AIKit's `AIDataDisclosure`, and the answer is remembered
// by the disclosure's `consentIdentifier`.

import AIKit
import Foundation

/// The consents the user gave to send a feature's data to a provider, in
/// `ai-data-consents` (an array of `consentIdentifier`s).
///
/// An identifier names the feature, the provider, and where its requests go,
/// so moving a provider to another host asks again.
struct AIConsentStore: Sendable {
    let store: PreferenceStore

    /// The stored consents.
    func load() -> Set<String> {
        Set(store.getStringArray(PreferenceKey.aiDataConsents))
    }

    /// Stores `consents`, removing the key when there are none.
    func save(_ consents: Set<String>) {
        if consents.isEmpty {
            store.remove(PreferenceKey.aiDataConsents)
        } else {
            store.setStringArray(PreferenceKey.aiDataConsents, consents.sorted())
        }
    }

    /// The identifiers of every disclosure `provider`'s requests could need,
    /// one per feature.
    static func consentIdentifiers(for provider: BYOKProvider) -> [String] {
        AIFeature.allCases.map { getAIDataDisclosure(for: $0, provider: provider).consentIdentifier }
    }
}

/// A consent the user gave: a feature may send its data to a provider.
public struct AIGrantedConsent: Sendable, Hashable, Identifiable {
    public let provider: BYOKProvider
    public let disclosure: AIDataDisclosure

    public var feature: AIFeature {
        disclosure.feature
    }

    public var id: String {
        disclosure.consentIdentifier
    }
}
