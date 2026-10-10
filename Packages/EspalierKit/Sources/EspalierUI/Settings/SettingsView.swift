// The Settings scene. Not the system's settings window: a sidebar lists the
// eight panes, as the main window's sidebar lists its places, and the pane
// shows beside it under a header band with its name. Changes apply
// immediately, and invalid values are never written. The window has its own
// context (SettingsWindowContext.swift), so a pane's alerts and sheets
// attach to it. Recoveries deep-link through `SettingsNavigation`
// (`Recovery.openSettings(pane)` selects the pane).

import EspalierCore
import GitKit
import SwiftUI

/// Settings: eight panes.
public struct SettingsView: View {
    private let model: AppModel?
    @Environment(SettingsNavigation.self) private var navigation

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        @Bindable var navigation = navigation
        Group {
            if let model {
                SettingsWindowRoot(model: model, navigation: navigation)
            } else {
                // Settings opened while Espalier is still launching.
                SettingsLayout(selection: $navigation.selectedTab) {
                    DelayedProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: Metrics.SettingsWindow.width, height: Metrics.SettingsWindow.height)
        .background(SettingsWindowChromeReader())
    }
}

/// The Settings window once the app model exists: its context, then the
/// panes.
struct SettingsWindowRoot: View {
    @State private var context: WindowContext
    private let navigation: SettingsNavigation
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, navigation: SettingsNavigation) {
        _context = State(initialValue: SettingsWindowContext.make(app: model, navigation: navigation))
        self.navigation = navigation
    }

    var body: some View {
        SettingsPanes(model: context.app, navigation: navigation)
            .settingsWindow(context)
            .onAppear {
                context.openWindow = openWindow
            }
    }
}

/// The sidebar and the selected pane.
struct SettingsPanes: View {
    let model: AppModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        SettingsLayout(selection: $navigation.selectedTab) {
            switch navigation.selectedTab {
            case .accounts: AccountsPane(model: model)
            case .git: GitPane(model: model)
            case .integrations: IntegrationsPane(model: model)
            case .appearance: AppearancePane(model: model)
            case .notifications: NotificationsPane(model: model)
            case .prompts: PromptsPane(model: model)
            case .ai: AIPane(model: model)
            case .advanced: AdvancedPane(model: model)
            }
        }
    }
}

/// The window's layout: the sidebar of panes on the left; on the right,
/// the header band with the selected pane's name and a hairline, then the
/// pane. It fills the window, under its transparent titlebar too.
struct SettingsLayout<Pane: View>: View {
    @Binding var selection: SettingsTab
    private let pane: Pane

    init(selection: Binding<SettingsTab>, @ViewBuilder pane: () -> Pane) {
        _selection = selection
        self.pane = pane()
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
            VStack(spacing: 0) {
                SettingsHeader(title: selection.title)
                pane
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // macOS 27 draws a pane's scroll edge effect up into
                    // the titlebar when the pointer is over it, blurring the
                    // header band; the band is opaque, so it needs none.
                    .scrollEdgeEffectHidden(true, for: .top)
            }
            .background(Color(espalier: Palette.background))
        }
        .ignoresSafeArea()
        .navigationTitle(selection.title)
        // Nor a toolbar background over the header band, nor the title in
        // the titlebar (the band shows it), as the main window: SwiftUI
        // draws the title once it manages the toolbar.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// The pane's header band: its name (13 bold, the headline) and a
/// hairline, as high as the main window's toolbar.
struct SettingsHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(Typography.paneTitle)
                .foregroundStyle(.text)
                .lineLimit(1)
                .padding(.horizontal, Metrics.SettingsWindow.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Hairline()
        }
        .frame(height: Metrics.SettingsWindow.headerHeight)
    }
}

/// The sidebar: the eight panes as the main window's sidebar draws its
/// places, rows 28 high with radius 9, the selected one in the neutral wash
/// with its symbol in the accent. It's one stop in the key view loop: the
/// up and down arrows choose a pane. Like the main window's sidebar, it
/// draws no ring while it has focus. VoiceOver reads each row as a button,
/// the chosen one selected.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @State private var hovered: SettingsTab?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.SettingsSidebar.rowSpacing) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                row(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Metrics.SettingsWindow.headerHeight + Metrics.SettingsSidebar.topSpacing)
        .padding(.horizontal, Metrics.Sidebar.rowInset)
        .frame(width: Metrics.SettingsWindow.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(espalier: Palette.sidebar))
        .overlay(alignment: .trailing) {
            Hairline(.vertical)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            move(by: -1)
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func row(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
        return SidebarRowLabel(tab.title, systemImage: tab.systemImage, isSelected: isSelected)
            .padding(.horizontal, Metrics.Sidebar.rowPadding)
            .frame(height: Metrics.RowHeight.sidebar)
            // Hover fades (in 0.08 s, out 0.15 s); choosing a pane is
            // instant, as selection is.
            .background(shape.fill(fill(for: tab)).hoverMotion(hovered == tab))
            .contentShape(shape)
            .onTapGesture {
                selection = tab
            }
            .onHover { isInside in
                if isInside {
                    hovered = tab
                } else if hovered == tab {
                    hovered = nil
                }
            }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                selection = tab
            }
    }

    private func fill(for tab: SettingsTab) -> Color {
        if tab == selection {
            return Color(espalier: Palette.sidebarSelection)
        }
        return tab == hovered ? Color(espalier: Palette.hover) : .clear
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let tabs = SettingsTab.allCases
        guard let index = tabs.firstIndex(of: selection) else {
            return .ignored
        }
        let next = index + offset
        if tabs.indices.contains(next) {
            selection = tabs[next]
        }
        return .handled
    }
}

extension Metrics {
    /// The Settings window's sidebar.
    public enum SettingsSidebar {
        /// Between rows.
        public static let rowSpacing: CGFloat = 1
        /// Between the top band and the first row.
        public static let topSpacing: CGFloat = 2
    }
}
