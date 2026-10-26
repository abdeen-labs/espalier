// Captures: Espalier's views drawn offscreen to PNGs, to look at with the
// Read tool. Nothing is compared, and no image is kept in the repository.
// A capture runs only when ESPALIER_CAPTURES names a folder
// (scripts/capture.sh sets it), and writes
// `<folder>/<look>/<Area>/<name>-<light|dark>.png`.
//
// ESPALIER_CAPTURE_LOOK=<theme>[-<color>][-<background>][-<app font>]
// [-<code font>], as the settings store them ("frost-iris",
// "islands-lagoon-warm-fixel", "pop-tangerine-atkinson-geistmono"), draws
// every capture in that look instead of Classic's; a capture made in a
// look of its own (`look:`) keeps it, and its name says which.
//
// SwiftUI views go into an `NSHostingView` in an offscreen key window with
// an explicit appearance; AppKit views go straight into the same kind of
// window. Images are drawn at 2x in sRGB, whatever the display.

import AppKit
import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

/// The appearances views are captured in.
enum CaptureAppearance: String, CaseIterable, Sendable {
    case light, dark

    var appearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }
}

extension Trait where Self == ConditionTrait {
    /// Runs a capture only when ESPALIER_CAPTURES names a folder, so the
    /// test suite skips them.
    static var captures: Self {
        .enabled(if: Capture.folder != nil, "Captures run when ESPALIER_CAPTURES names a folder")
    }
}

/// A window that reports key and main, so controls draw their active look,
/// and draws in sRGB rather than in the color profile of whichever screen
/// it would be on.
final class CaptureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        colorSpace = .sRGB
    }
}

/// An empty defaults domain of the run's own, for views drawn outside a
/// window context: nothing the developer's settings saved changes what
/// they draw.
enum CaptureDefaults {
    nonisolated(unsafe) static let empty: UserDefaults = {
        let suiteName = POSIXPath.join(NSTemporaryDirectory(), "EspalierCaptureDefaults-\(UUID().uuidString)")
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()
}

/// Draws views offscreen and writes them.
@MainActor
enum Capture {
    /// Where captures go: ESPALIER_CAPTURES, else nil (captures don't run).
    nonisolated static let folder: URL? = {
        guard let path = ProcessInfo.processInfo.environment["ESPALIER_CAPTURES"], !path.isEmpty else {
            return nil
        }
        return URL(exactFilePath: path, isDirectory: true)
    }()

    /// The look captures draw in: ESPALIER_CAPTURE_LOOK's, else Classic.
    /// It's made the process's too, so views that read the process's look
    /// draw in it.
    static let look: Look = {
        let look = ProcessInfo.processInfo.environment["ESPALIER_CAPTURE_LOOK"].map(Look.init(captureName:)) ?? .classic
        LookCenter.shared.look = look
        return look
    }()

    /// The scale images are drawn at.
    static let scale: CGFloat = 2

    /// The number format captures show counts in: English's.
    static let numberFormat = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

    /// The environment every hosted view gets: English and its number
    /// format, monograms, and no motion (a state change never draws a frame
    /// from the middle of an animation).
    static func prepared(_ view: some View) -> some View {
        view
            .environment(\.motionSuppressed, true)
            .environment(\.appearsActive, true)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.numberFormat, numberFormat)
            .environment(\.avatarLoader, MonogramAvatarLoader())
            .defaultAppStorage(CaptureDefaults.empty)
            .lookFont()
    }

    /// Draws a SwiftUI view on the window background: at `size`, else at
    /// its fitting size. `prepare` gets the laid-out host in its window
    /// before drawing (to give a field focus).
    static func render(
        _ view: some View,
        size: CGSize? = nil,
        appearance: CaptureAppearance,
        prepare: (NSView) -> Void = { _ in }
    ) -> NSBitmapImageRep {
        let root = prepared(view)
            .background(Color(nsColor: Palette.background))
        let host = NSHostingView(rootView: root)
        let window = CaptureWindow(
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
        return image(of: host)
    }

    /// Draws an AppKit view at `size`, over the window background.
    static func render(_ view: NSView, size: CGSize, appearance: CaptureAppearance) -> NSBitmapImageRep {
        let window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        view.frame = container.bounds
        container.addSubview(view)
        window.contentView = container
        defer { window.contentView = nil }
        container.layoutSubtreeIfNeeded()
        let content = image(of: container)
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

    /// Draws `view` as it's laid out.
    static func image(of view: NSView) -> NSBitmapImageRep {
        let content = bitmap(view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: content)
        return content
    }

    /// An empty bitmap of `size` points at `scale`, in sRGB.
    static func bitmap(_ size: CGSize) -> NSBitmapImageRep {
        let width = max(size.width.rounded(.up), 1)
        let height = max(size.height.rounded(.up), 1)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
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

    /// Writes `image` as `<folder>/<run's look>/<area>/<name>-<appearance>.png`.
    static func write(
        _ image: NSBitmapImageRep,
        named name: String,
        area: String,
        appearance: CaptureAppearance,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let folder else {
            return
        }
        let directory = folder
            .appending(path: look.captureName, directoryHint: .isDirectory)
            .appending(path: area, directoryHint: .isDirectory)
        let fileName = "\(name)-\(appearance.rawValue).png"
        do {
            guard let png = image.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: fileName))
        } catch {
            Issue.record("Couldn't write \(area)/\(fileName): \(error)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Capturing

/// Captures a SwiftUI view in each appearance, in `look` (else the run's),
/// drawn in the task's look while the process's stays as it is.
@MainActor
func capture(
    _ view: some View,
    named name: String,
    area: String,
    size: CGSize? = nil,
    look: Look? = nil,
    appearances: [CaptureAppearance] = CaptureAppearance.allCases,
    prepare: (NSView) -> Void = { _ in },
    sourceLocation: SourceLocation = #_sourceLocation
) {
    capture(named: name, area: area, look: look, appearances: appearances, sourceLocation: sourceLocation) { appearance in
        Capture.render(view, size: size, appearance: appearance, prepare: prepare)
    }
}

/// Captures an AppKit view, made in each appearance, in `look` (else the
/// run's).
@MainActor
func capture(
    _ makeView: () -> NSView,
    named name: String,
    area: String,
    size: CGSize,
    look: Look? = nil,
    appearances: [CaptureAppearance] = CaptureAppearance.allCases,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    capture(named: name, area: area, look: look, appearances: appearances, sourceLocation: sourceLocation) { appearance in
        Capture.render(makeView(), size: size, appearance: appearance)
    }
}

/// Captures what `draw` draws in each appearance, in `look` (else the
/// run's): the way in for drawing that isn't a view.
@MainActor
func capture(
    named name: String,
    area: String,
    look: Look? = nil,
    appearances: [CaptureAppearance] = CaptureAppearance.allCases,
    sourceLocation: SourceLocation = #_sourceLocation,
    draw: (CaptureAppearance) -> NSBitmapImageRep
) {
    let drawnLook = look ?? Capture.look
    let fileName = look.map { "\(name)-\($0.captureName)" } ?? name
    for appearance in appearances {
        let image = Look.with(drawnLook) {
            draw(appearance)
        }
        Capture.write(image, named: fileName, area: area, appearance: appearance, sourceLocation: sourceLocation)
    }
}

extension Look {
    /// The look's name in captures: "classic" for Classic in System, its
    /// own backgrounds, in Geist and Geist Mono; else the theme, then the
    /// palette, the background tint, the app font, and the code font when
    /// they aren't the defaults ("frost-iris", "classic-warm",
    /// "islands-lagoon-fixel", "pop-tangerine-sfmono").
    var captureName: String {
        var parts = [theme.rawValue]
        if palette != .system {
            parts.append(palette.rawValue)
        }
        if background != .own {
            parts.append(background.rawValue)
        }
        if appFont != .geist {
            parts.append(appFont.rawValue)
        }
        if codeFont != .geistMono {
            parts.append(codeFont.rawValue)
        }
        return parts.joined(separator: "-")
    }

    /// The look a capture name spells; a part that names nothing stops the
    /// run.
    init(captureName name: String) {
        var parts = name.split(separator: "-").map(String.init)
        guard let first = parts.first, let theme = DesignTheme(rawValue: first) else {
            fatalError("ESPALIER_CAPTURE_LOOK=\(name) doesn't start with a theme")
        }
        parts.removeFirst()
        var palette = DesignPalette.system
        var background = BackgroundTint.own
        var appFont = AppFont.geist
        var codeFont = CodeFont.geistMono
        for part in parts {
            if let named = DesignPalette(rawValue: part) {
                palette = named
            } else if let named = BackgroundTint(rawValue: part) {
                background = named
            } else if let named = AppFont(rawValue: part) {
                appFont = named
            } else if let named = CodeFont(rawValue: part) {
                codeFont = named
            } else {
                fatalError("ESPALIER_CAPTURE_LOOK=\(name): \(part) is neither a palette, a background, an app font, nor a code font")
            }
        }
        self.init(theme: theme, palette: palette, background: background, appFont: appFont, codeFont: codeFont)
    }
}
