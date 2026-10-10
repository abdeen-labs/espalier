// Which Settings pane shows. Recoveries deep-link to a pane
// (`Recovery.openSettings`).

import EspalierCore
import GitKit
import Observation

/// The eight Settings panes, in the sidebar's order.
nonisolated public enum SettingsTab: String, CaseIterable, Sendable, Hashable {
    case accounts, git, integrations, appearance, notifications, prompts, ai, advanced

    /// The pane for one of the state layer's panes (Appearance for any pane
    /// the Settings scene doesn't have).
    public init(_ pane: SettingsPane) {
        self = SettingsTab(rawValue: pane.rawValue) ?? .appearance
    }

    public var title: String {
        switch self {
        case .accounts: "Accounts"
        case .git: "Git"
        case .integrations: "Integrations"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .prompts: "Prompts"
        case .ai: "AI"
        case .advanced: "Advanced"
        }
    }

    public var systemImage: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .git: "arrow.trianglehead.branch"
        case .integrations: "hammer"
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .prompts: "text.bubble"
        case .ai: "sparkles"
        case .advanced: "gearshape"
        }
    }
}

/// The Settings scene's selected pane, shared by the main window (which
/// deep-links) and the Settings scene.
@MainActor @Observable
public final class SettingsNavigation {
    public var selectedTab: SettingsTab = .accounts

    public init() {}

    /// Selects the pane for one of the state layer's panes.
    public func select(_ pane: SettingsPane) {
        selectedTab = SettingsTab(pane)
    }
}
