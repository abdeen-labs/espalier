// Fixed values for the Settings tests: accounts, AI providers (mock ones;
// no key reaches a real server), and the Settings window's context on a
// hermetic app.

import AIKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import TestSupport
@testable import EspalierUI

@MainActor
enum SettingsFixtures {
    // MARK: Accounts

    /// A GitHub.com account with a verified address and its private one.
    static let dotComAccount = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [
            APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public),
            APIEmail(email: "joe@unverified.example.com", verified: false, primary: false, visibility: .private),
        ],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    // MARK: AI providers

    /// A local OpenAI-compatible server without credentials.
    static let localProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000001",
        name: "Ollama",
        type: .openai,
        baseUrl: "http://localhost:11434/v1",
        wireApi: .completions,
        authKind: .none,
        models: [BYOKModel(id: "llama3:latest", name: "Llama 3")]
    )

    /// A remote provider with an API key and two models, one with a
    /// reasoning effort.
    static let remoteProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000002",
        name: "OpenAI",
        type: .openai,
        baseUrl: "https://api.openai.com/v1",
        wireApi: .responses,
        authKind: .apiKey,
        requestTimeoutSeconds: 120,
        models: [
            BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .high),
            BYOKModel(id: "gpt-5-mini", name: "GPT-5 mini"),
        ]
    )

    // MARK: Apps

    /// A hermetic app (not loaded: nothing runs at launch).
    static func app(_ harness: AppHarness) -> AppModel {
        harness.makeApp()
    }

    /// The Settings window's context on `app`, with Settings shown at
    /// `tab`.
    static func context(_ app: AppModel, tab: SettingsTab = .accounts) -> (WindowContext, SettingsNavigation) {
        let navigation = SettingsNavigation()
        navigation.selectedTab = tab
        let context = SettingsWindowContext.make(app: app, navigation: navigation)
        context.avatarLoader = MonogramAvatarLoader()
        return (context, navigation)
    }
}
