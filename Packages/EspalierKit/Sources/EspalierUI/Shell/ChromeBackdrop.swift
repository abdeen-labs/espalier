// The main window's chrome in the inset card layout (InsetCard.swift): the
// toolbar's band, the sidebar or the rail, and the margins around the card
// are the theme's backdrop. Where the backdrop is glass
// (`Theme.backdropGlass`, Frost's), it's the backdrop color at the glass's
// opacity over a blur of what's behind the window: `NSVisualEffectView`'s
// full-screen UI material, blended behind the window, the system's most
// see-through (under the color, the others are near opaque), which goes
// still in an inactive window as the system's own sidebars do. Reduce
// Transparency and Increase Contrast give the backdrop color alone, opaque,
// and the chrome follows either setting as it changes.
//
// Each part of the chrome draws its own backdrop (a blur of what's behind
// the window is the same wherever it's drawn): the sidebar's covers the
// Liquid Glass of its column, and the sidebar filter's the rows that scroll
// under it.

import AppKit
import SwiftUI

/// The chrome's surface: the backdrop in the inset card layout
/// (`ChromeBackdrop`), else `color`.
struct ChromeSurface: View {
    private let color: NSColor

    init(_ color: NSColor) {
        self.color = color
    }

    var body: some View {
        if InsetCard.isOn {
            ChromeBackdrop()
        } else {
            Color(espalier: color)
        }
    }
}

/// The theme's backdrop: glass where the theme's is, opaque under Reduce
/// Transparency and Increase Contrast.
struct ChromeBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> ChromeBackdropView {
        ChromeBackdropView()
    }

    func updateNSView(_ view: ChromeBackdropView, context: Context) {
        view.environmentIsOpaque = reducesTransparency || contrast == .increased
    }
}

/// The backdrop color over the material, or alone and opaque.
final class ChromeBackdropView: NSView, LookChangeObserving {
    /// The blur of what's behind the window.
    private let material = NSVisualEffectView()
    /// The backdrop color over it.
    private let tint = NSView()

    /// Whether the view's environment has Reduce Transparency or Increase
    /// Contrast on (as the Mac's settings do, or as captures set it).
    var environmentIsOpaque = false {
        didSet {
            if environmentIsOpaque != oldValue {
                applyStyle()
            }
        }
    }

    /// Whether the backdrop is opaque whatever the theme's glass: Reduce
    /// Transparency or Increase Contrast is on, in the environment or in
    /// the Mac's settings.
    private var backdropIsOpaque: Bool {
        let workspace = NSWorkspace.shared
        return environmentIsOpaque
            || workspace.accessibilityDisplayShouldReduceTransparency
            || workspace.accessibilityDisplayShouldIncreaseContrast
    }

    init() {
        super.init(frame: .zero)
        material.material = .fullScreenUI
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        tint.wantsLayer = true
        addSubview(tint)
        applyStyle()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The chrome takes no clicks: they go to what's behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    func lookDidChange() {
        applyStyle()
    }

    @objc private func displayOptionsDidChange() {
        applyStyle()
    }

    /// The material where the backdrop is glass, and the backdrop color at
    /// the glass's opacity over it; the color alone, opaque, otherwise.
    private func applyStyle() {
        let theme = Theme.current
        let glass = backdropIsOpaque ? nil : theme.backdropGlass
        material.isHidden = glass == nil
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = theme.backdrop.cgColor.copy(alpha: glass?.opacity ?? 1)
        }
        tint.layer?.backgroundColor = color
    }
}
