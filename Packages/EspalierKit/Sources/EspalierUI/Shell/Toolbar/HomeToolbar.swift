// The toolbar's part in Home: the Home button before the location control
// while Home is on, and what the toolbar shows while the window is on Home.
// There, a "Home" capsule takes the location control's place, the items
// bound to a repository (Changes | History, the pull request chip, the list
// search, the last fetch and the sync button, Commit Info, and the
// customizable extras) aren't there, and a field that opens the command
// palette takes the search field's. The overflow menu keeps what makes
// sense without a repository. With Home off, the toolbar is as it was.

import EspalierCore
import SwiftUI

/// What the toolbar offers, from Home's setting and whether the window is
/// on Home.
nonisolated struct ToolbarOffer: Sendable, Equatable {
    /// What leads the toolbar after the Home button.
    enum Location: Sendable, Equatable {
        /// The location control: the repository and the branch.
        case location
        /// The "Home" capsule.
        case home
    }

    /// What the overflow menu holds.
    enum Overflow: Sendable, Equatable {
        /// The repository's places outside Espalier, on GitHub, and its
        /// settings.
        case repository
        /// Adding a repository: New, Add, and Clone.
        case addRepository
    }

    /// The Home button, which goes to Home.
    var showsHomeButton: Bool
    var location: Location
    /// The items bound to a repository: Changes | History, the pull request
    /// chip, the list search, the last fetch and the sync button, Commit
    /// Info, and the customizable extras.
    var showsRepositoryItems: Bool
    /// The field that opens the command palette, in the list search's
    /// place.
    var showsJumpField: Bool
    var overflow: Overflow

    /// - Parameters:
    ///   - showsHome: Whether Home is on (`Preferences.showsHome`).
    ///   - isOnHome: Whether the window shows Home.
    static func make(showsHome: Bool, isOnHome: Bool) -> ToolbarOffer {
        let isOnHome = showsHome && isOnHome
        return ToolbarOffer(
            showsHomeButton: showsHome && !isOnHome,
            location: isOnHome ? .home : .location,
            showsRepositoryItems: !isOnHome,
            showsJumpField: isOnHome,
            overflow: isOnHome ? .addRepository : .repository
        )
    }

    /// What `context`'s window's toolbar offers.
    @MainActor
    static func make(_ context: WindowContext) -> ToolbarOffer {
        let destination = DetailDestination.make(app: context.app, isShowingHome: context.state.isShowingHome, place: context.state.place)
        return make(showsHome: context.app.preferences.showsHome, isOnHome: destination == .home)
    }
}

/// The Home button: a quiet round control with the house, the location
/// control's height, that goes to Home.
struct HomeButton: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        Button {
            context.actions.perform(.showHome)
        } label: {
            ToolbarSymbol("house")
                .accessibilityLabel(ActionKind.showHome.title)
        }
        .buttonStyle(QuietRoundButtonStyle())
        .tooltip(Self.tooltip)
    }

    /// "Home (⌃⌘H)".
    static var tooltip: String {
        guard let shortcut = ActionKind.showHome.shortcut?.symbols else {
            return ActionKind.showHome.title
        }
        return "\(ActionKind.showHome.title) (\(shortcut))"
    }
}

/// Show Sidebar and Hide Sidebar: Espalier's own toggle in the place of the
/// split view's, a quiet round control drawn as the Home button is.
struct SidebarToggleButton: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        let title = context.actions.title(for: .toggleSidebar)
        Button {
            context.actions.perform(.toggleSidebar)
        } label: {
            ToolbarSymbol("sidebar.left")
                .accessibilityLabel(title)
        }
        .buttonStyle(QuietRoundButtonStyle())
        .tooltip(ActionKind.toggleSidebar.shortcut.map { "\(title) (\($0.symbols))" } ?? title)
    }
}

/// A symbol in the toolbar's quiet controls: the Home button's and the
/// sidebar toggle's, and the Home capsule's house, in the row's font and
/// secondary text.
struct ToolbarSymbol: View {
    private let systemImage: String

    init(_ systemImage: String) {
        self.systemImage = systemImage
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(Typography.row)
            .foregroundStyle(.text2)
    }
}

/// A quiet round button as tall as the location control, in its capsule's
/// look: a pillow on its lip, or flat.
struct QuietRoundButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: QuietRoundButtonDrawing())
    }
}

private struct QuietRoundButtonDrawing: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietRoundButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct QuietRoundButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let isPillow = Theme.current.style.toolbar.locationControl == .pillow
        let appearance = CapsuleButtonAppearance(kind: .quiet, controlSize: .large, isPressed: isPressed, isHovered: isHovered, isEnabled: isEnabled)
        let side = Metrics.LocationControl.height
        label
            .foregroundStyle(.text)
            .frame(width: side, height: side)
            .quietControlSurface()
            .overlay(
                Circle().fill(appearance.stateOverlay)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .allowsHitTesting(false)
            )
            .contentShape(Circle())
            .opacity(appearance.opacity)
            .focusRing(isFocused, in: Circle())
            .onLip(isPillow ? appearance.lip : nil, isPressed: isPressed)
            .onHover { isHovered = $0 }
    }
}

/// The "Home" capsule in the location control's place while the window is
/// on Home: the house and the word, in the location control's capsule. It
/// opens the repository popover (⌘T), as the location control's repository
/// does.
struct HomeLocationControl: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        @Bindable var state = context.state
        HomeLocationView {
            context.actions.perform(.switchRepository)
        }
        .tooltip(context.actions.title(for: .switchRepository).replacingOccurrences(of: "…", with: ""))
        .popoverCard(isPresented: $state.isRepositoryPopoverPresented, title: "Repositories") {
            RepositoryPopover()
                .windowEnvironment(context)
        }
    }
}

/// The "Home" capsule's look.
struct HomeLocationView: View {
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        let look = Theme.current.style.toolbar.locationControl
        Button(action: action) {
            HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
                ToolbarSymbol("house")
                    .frame(width: Metrics.symbolWidth)
                Text(ActionKind.showHome.title)
                    .lineLimit(1)
            }
            .padding(.horizontal, Metrics.LocationControl.segmentPadding)
            .frame(maxHeight: .infinity)
            .background {
                Capsule(style: .circular)
                    .fill(isHovered ? Color(nsColor: Palette.hover) : .clear)
                    .hoverMotion(isHovered)
                    .padding(.vertical, Metrics.LocationControl.hoverInset)
            }
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.bare(.capsule))
        .onHover { isHovered = $0 }
        .font(Metrics.LocationControl.font)
        .foregroundStyle(.text)
        .padding(.horizontal, Metrics.LocationControl.inset)
        .frame(height: Metrics.LocationControl.height)
        .quietControlSurface()
        .onLip(look == .pillow ? CapsuleButtonAppearance(kind: .quiet, controlSize: .large).lip : nil, isPressed: false)
        .fixedSize()
    }
}

/// The field in the list search's place while the window is on Home: it
/// reads "Jump to a repository or branch", with the command palette's key
/// cap, and opens the command palette.
struct JumpField: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        JumpFieldView(keyCap: ActionKind.showCommandPalette.shortcut?.symbols) {
            context.actions.perform(.showCommandPalette)
        }
        .environment(\.searchFieldIsRaised, PaneCards.floats)
    }
}

/// The jump field's look: a search field's capsule, its prompt, and the
/// key cap.
struct JumpFieldView: View {
    static let prompt = "Jump to a repository or branch"

    let keyCap: String?
    var action: () -> Void = {}
    @Environment(\.searchFieldIsRaised) private var isRaised
    @State private var isHovered = false

    var body: some View {
        let raised = CapsuleButtonAppearance(kind: .quiet, controlSize: .large, isHovered: isHovered)
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.text3)
            Text(Self.prompt)
                .font(Typography.row)
                .foregroundStyle(.text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let keyCap {
                KeyCap(keyCap)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: Metrics.Toolbar.jumpFieldWidth, height: isRaised ? raised.capsuleHeight : Metrics.ControlHeight.height(for: .large))
        .background {
            if isRaised {
                Color.clear
                    .surface(.quiet, elevation: .quiet)
            } else {
                Capsule(style: .circular).fill(.field)
            }
        }
        .overlay(
            Capsule(style: .circular)
                .fill(isHovered ? Color(nsColor: Palette.hover) : .clear)
                .hoverMotion(isHovered)
                .allowsHitTesting(false)
        )
        .onLip(isRaised ? raised.lip : nil, isPressed: false)
        .contentShape(Capsule(style: .circular))
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.prompt)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .fixedSize()
    }
}

extension Metrics.Toolbar {
    /// The jump field's width: its prompt and key cap.
    static let jumpFieldWidth: CGFloat = 280
}
