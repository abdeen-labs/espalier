// Rendering views to PNG without a running app. SwiftUI views go into an
// `NSHostingView` in an offscreen key window with an explicit appearance;
// AppKit views (tables, alerts) go straight into the same kind of window.
// Images are rendered at 1x in sRGB, so the references stay small and don't
// depend on the display: a bitmap made from the window
// (`bitmapImageRepForCachingDisplay`) takes the screen's color profile and
// scale, so the same table would draw its accent blue in different numbers
// with another main display connected.

import AppKit
import EspalierSupport
import SwiftUI
@testable import EspalierUI

/// The appearances snapshots are rendered in.
enum SnapshotAppearance: String, CaseIterable, Sendable {
    case light, dark

    var appearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }
}

/// A window that reports key and main, so controls draw their active look,
/// and draws in sRGB rather than in the color profile of whichever screen it
/// would be on.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        colorSpace = .sRGB
    }
}

/// An empty defaults domain of the test run's own, for views a snapshot
/// draws outside a window context: no state the developer's or another
/// run's tests saved changes what they draw.
enum SnapshotDefaults {
    nonisolated(unsafe) static let empty: UserDefaults = {
        let suiteName = POSIXPath.join(NSTemporaryDirectory(), "EspalierSnapshotDefaults-\(UUID().uuidString)")
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()
}

/// Renders views to bitmaps.
@MainActor
enum Snapshot {
    /// The environment every snapshot gets: a fixed clock and time zone,
    /// English, monograms, delayed content shown at once, and no motion (a
    /// state change never draws a frame from the middle of an animation).
    static func deterministic(_ view: some View) -> some View {
        view
            .environment(\.motionSuppressed, true)
            .environment(\.appearsActive, true)
            .environment(\.fixedNow, UIFixtures.now)
            .environment(\.timeZone, UIFixtures.timeZone)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.avatarLoader, MonogramAvatarLoader())
            .environment(\.showsDelayedContentImmediately, true)
            .environment(\.savesSplitDividers, false)
            .defaultAppStorage(SnapshotDefaults.empty)
    }

    /// Renders a SwiftUI view on the window background. With no size, the
    /// view's fitting size. `prepare` gets the laid-out host in its window
    /// before drawing (to give a field focus).
    static func render(
        _ view: some View,
        size: CGSize? = nil,
        appearance: SnapshotAppearance,
        prepare: (NSView) -> Void = { _ in }
    ) -> NSBitmapImageRep {
        let root = deterministic(view)
            .background(Color(nsColor: Palette.background))
        let host = NSHostingView(rootView: root)
        let window = SnapshotWindow(
            contentRect: CGRect(origin: .zero, size: size ?? CGSize(width: 400, height: 300)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.appearance
        window.contentView = host
        defer { window.contentView = nil }
        let fitting = size ?? host.fittingSize
        let bounds = CGRect(origin: .zero, size: CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        window.setContentSize(bounds.size)
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        prepare(host)
        host.layoutSubtreeIfNeeded()
        return cache(host, appearance: appearance)
    }

    /// Renders an AppKit view.
    static func render(_ view: NSView, size: CGSize, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        view.frame = container.bounds
        container.addSubview(view)
        window.contentView = container
        defer { window.contentView = nil }
        container.layoutSubtreeIfNeeded()
        return cache(container, appearance: appearance, fillsBackground: true)
    }

    /// Renders an alert as `ModalPresenter` would show it, on the window
    /// background.
    static func render(_ content: AlertContent, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let alert = content.makeAlert()
        alert.window.appearance = appearance.appearance
        alert.layout()
        guard let view = alert.window.contentView else {
            return blank(CGSize(width: 1, height: 1))
        }
        view.layoutSubtreeIfNeeded()
        return cache(view, appearance: appearance, fillsBackground: true)
    }

    /// Draws `view` as it's laid out into a 1x sRGB bitmap: the same pixels
    /// whatever the display.
    static func image(of view: NSView) -> NSBitmapImageRep {
        let content = bitmap(view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: content)
        return content
    }

    /// Draws `view` into a 1x bitmap, over the window background when
    /// `fillsBackground`.
    private static func cache(_ view: NSView, appearance: SnapshotAppearance, fillsBackground: Bool = false) -> NSBitmapImageRep {
        let size = view.bounds.size
        let content = image(of: view)
        guard fillsBackground else {
            return content
        }
        let result = bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        appearance.appearance.performAsCurrentDrawingAppearance {
            Palette.background.setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        content.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return result
    }

    /// An empty 1x bitmap in sRGB.
    static func bitmap(_ size: CGSize) -> NSBitmapImageRep {
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = CGSize(width: width, height: height)
        // Device RGB already draws as sRGB here; the tag makes it explicit.
        return rep.retagging(with: .sRGB) ?? rep
    }

    private static func blank(_ size: CGSize) -> NSBitmapImageRep {
        bitmap(size)
    }
}
