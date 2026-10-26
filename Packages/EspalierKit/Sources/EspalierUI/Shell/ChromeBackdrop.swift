// The main window's chrome in the inset card layout (InsetCard.swift): the
// toolbar's band, the sidebar or the rail, and the margins around the card
// are the theme's backdrop. Where the backdrop is glass
// (`Theme.backdropGlass`, Frost's), it's built in three layers:
// a plain blur of what's behind the window (`PlainBlurView`), the backdrop
// color at the glass's opacity over it, and the glass's wash over that.
// Reduce Transparency and Increase Contrast give the backdrop color alone,
// opaque, and the chrome follows either setting as it changes.
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

/// The backdrop color and the glass's wash over the blur, or the color
/// alone and opaque.
final class ChromeBackdropView: NSView, LookChangeObserving {
    /// The blur of what's behind the window.
    private let material = PlainBlurView(frame: .zero)
    /// The backdrop color over it.
    private let tint = NSView()
    /// The glass's wash over the color.
    private let wash = NSView()

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
        addSubview(material)
        tint.wantsLayer = true
        addSubview(tint)
        wash.wantsLayer = true
        addSubview(wash)
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
        wash.frame = bounds
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

    /// The blur where the backdrop is glass, the backdrop color at the
    /// glass's opacity over it, and the glass's wash over that; the color
    /// alone, opaque, otherwise.
    private func applyStyle() {
        let theme = Theme.current
        let glass = backdropIsOpaque ? nil : theme.backdropGlass
        material.isHidden = glass == nil
        var color: CGColor?
        var washColor: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = theme.backdrop.cgColor.copy(alpha: glass?.opacity ?? 1)
            washColor = glass?.wash?.cgColor
        }
        tint.layer?.backgroundColor = color
        wash.layer?.backgroundColor = washColor
        wash.isHidden = washColor == nil
    }
}

/// A blur of what's behind the window with no color of its own: the
/// under-window material, always active, with its tint, its desktop
/// tinting, and its added saturation taken out, and its blur widened to
/// 60 points. A black base under the blur shows only where
/// the blur isn't drawn (Mission Control's snapshots of the window).
final class PlainBlurView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else {
            return
        }
        Self.removeColor(from: layer)
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Takes the material's color out of `layer` and the layers in it: their
    /// backgrounds, the desktop tinting layer, and the saturation filter,
    /// with the blur filter's radius at 60.
    private static func removeColor(from layer: CALayer) {
        layer.backgroundColor = nil
        if NSStringFromClass(type(of: layer)) == "CAChameleonLayer" {
            layer.isHidden = true
            return
        }
        if let filters = layer.filters, !filters.isEmpty {
            for filter in filters where String(describing: filter).contains("Blur") {
                (filter as? NSObject)?.setValue(60.0, forKey: "inputRadius")
            }
            layer.filters = filters.filter { !String(describing: $0).contains("Saturat") }
        }
        for sublayer in layer.sublayers ?? [] {
            removeColor(from: sublayer)
        }
    }
}
