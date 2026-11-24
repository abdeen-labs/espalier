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
        .frame(width: Metrics.SettingsCards.windowWidth, height: Metrics.SettingsWindow.height)
        .background(SettingsWindowChromeReader())
        .lookFont()
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
/// the header band with the selected pane's name, then the pane. It fills the window, under its transparent
/// titlebar too. In the floating layout the band and the pane sit on the
/// backdrop; in the inset card layout, on the background, with a hairline
/// under the band.
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
                SettingsHeader(tab: selection)
                pane
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // macOS 27 draws a pane's scroll edge effect up into
                    // the titlebar when the pointer is over it, blurring the
                    // header band; the pane needs none.
                    .scrollEdgeEffectHidden(true, for: .top)
                    // Clipped to the pane, content scrolls out of sight at
                    // the band's edge instead of over the name.
                    .clipped()
            }
            .background(Color(espalier: PaneCards.floats ? Theme.current.backdrop : Palette.background))
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

/// The pane's header band: its name in the theme's pane title, as high as
/// the main window's toolbar, inset as the page is, and a hairline under it
/// in the inset card layout.
struct SettingsHeader: View {
    let tab: SettingsTab

    var body: some View {
        Text(tab.title)
            .font(Typography.settingsPaneTitle)
            .foregroundStyle(.text)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .padding(
                .horizontal,
                Theme.current.style.settings.groups == .cards ? Metrics.SettingsCards.pageInset : Metrics.SettingsWindow.contentInset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: Metrics.SettingsWindow.headerHeight)
            .overlay(alignment: .bottom) {
                Hairline()
                    .opacity(PaneCards.floats ? 0 : 1)
            }
    }
}

/// The sidebar: the eight panes in the theme's look
/// (`SettingsThemeStyle.Sidebar`): tiled rows, as System Settings lists its
/// panes, each a symbol on its colored tile beside the name; or as the main
/// window's sidebar draws its rows, each with its plain symbol, at their
/// height. The selected one is in the sidebar's selection. It's one stop in the key view
/// loop: the up and down arrows choose a pane. Like the main window's
/// sidebar, it draws no ring while it has focus. VoiceOver reads each row
/// as a button, the chosen one selected.
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
        .frame(width: Metrics.SettingsCards.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(espalier: Palette.sidebar))
        .overlay(alignment: .trailing) {
            Hairline(.vertical)
                .opacity(PaneCards.floats ? 0 : 1)
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
        let isTiled = Theme.current.style.settings.sidebar == .tiles
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
        return Group {
            if isTiled {
                HStack(spacing: Metrics.insetMedium - 2) {
                    PlaceTile(systemImage: tab.tileSymbol, color: tab.tileColor, size: Metrics.SettingsCards.sidebarTile)
                    Text(tab.title)
                        .font(isSelected ? Typography.row.weight(.semibold) : Typography.row)
                        .foregroundStyle(.sidebarRowText(isSelected: isSelected))
                        .lineLimit(1)
                }
            } else {
                SidebarRowLabel(tab.title, systemImage: tab.systemImage, isSelected: isSelected)
            }
        }
        .padding(.horizontal, isTiled ? Metrics.SettingsSidebar.rowPadding : Metrics.Sidebar.rowPadding)
        .frame(height: isTiled ? Metrics.SettingsCards.sidebarRowHeight : Metrics.SettingsSidebar.symbolRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover fades (in 0.08 s, out 0.15 s); choosing a pane is
        // instant, as selection is.
        .background(shape.fill(fill(for: tab)).hoverMotion(hovered == tab))
        .background {
            if isSelected {
                SidebarSelectionFill()
            }
        }
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selection = tab
        }
    }

    private func fill(for tab: SettingsTab) -> Color {
        if tab == selection {
            // `SidebarSelectionFill`, under it.
            return .clear
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

extension SettingsTab {
    /// The pane's tile color, as System Settings colors its panes.
    var tileColor: NSColor {
        switch self {
        case .accounts: TileColor.blueberry
        case .git: TileColor.apricot
        case .integrations: TileColor.honey
        case .appearance: TileColor.plum
        case .notifications: TileColor.tomato
        case .prompts: TileColor.teal
        case .ai: TileColor.grape
        case .advanced: TileColor.slate
        }
    }

    /// The symbol on the pane's tile: the pane's symbol, filled where it
    /// has a filled form.
    var tileSymbol: String {
        switch self {
        case .accounts: "person.fill"
        case .git: systemImage
        case .integrations: "hammer.fill"
        case .appearance: "paintbrush.fill"
        case .notifications: "bell.fill"
        case .prompts: "text.bubble.fill"
        case .ai: systemImage
        case .advanced: "gearshape.fill"
        }
    }
}

extension Metrics {
    /// The Settings window's sidebar.
    public enum SettingsSidebar {
        /// Between rows: tiled ones, and ones with plain symbols.
        public static var rowSpacing: CGFloat {
            Theme.current.style.settings.sidebar == .tiles ? 2 : 1
        }
        /// Between the top band and the first row.
        public static let topSpacing: CGFloat = 2
        /// Inside a tiled row, before its tile.
        public static let rowPadding: CGFloat = 6
        /// A row with a plain symbol.
        public static let symbolRowHeight: CGFloat = 28
    }
}
