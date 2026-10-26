// The look Espalier draws in: the design theme, the palette, the background
// tint, the app font, and the code font, each picked in Settings ▸
// Appearance apart from the others (and from the appearance, System, Light,
// or Dark). One look is current for the process (`LookCenter`); reading it
// in a SwiftUI body makes the view draw again when it changes, and
// `LookApplier` tells the AppKit views.
// A task can draw in a look of its own (`Look.with(_:operation:)`) without
// touching the process's.

import EspalierCore
import Foundation
import Observation
import Synchronization

/// The design theme, the palette, the background tint, the app font, and
/// the code font.
nonisolated public struct Look: Sendable, Hashable {
    public var theme: DesignTheme
    public var palette: DesignPalette
    /// The tint of the theme's backgrounds.
    public var background: BackgroundTint
    /// The interface's text.
    public var appFont: AppFont
    /// What's drawn monospaced.
    public var codeFont: CodeFont

    /// A look; a background the theme doesn't offer is its own.
    public init(theme: DesignTheme = .classic, palette: DesignPalette = .system, background: BackgroundTint = .own, appFont: AppFont = .sf, codeFont: CodeFont = .sfMono) {
        self.theme = theme
        self.palette = palette
        self.background = theme.backgroundDrawn(for: background)
        self.appFont = appFont
        self.codeFont = codeFont
    }

    /// Classic in the Mac's accent color, its own backgrounds, in SF Pro
    /// and SF Mono: the look before themes.
    public static let classic = Look()

    /// The look the current task draws in: its own (`with(_:operation:)`),
    /// else the process's.
    public static var current: Look {
        taskLook ?? LookCenter.shared.look
    }

    @TaskLocal private static var taskLook: Look?

    /// Runs `operation` drawing in `look`, for its task alone: what it
    /// does synchronously reads `look` wherever it reads the current one,
    /// while the process's stays as it is.
    public static func with<T>(_ look: Look, operation: () throws -> T) rethrows -> T {
        try $taskLook.withValue(look, operation: operation)
    }
}

/// The process's current look. Reads are tracked by Observation, so a
/// SwiftUI view that reads a theme's color or font draws again when the
/// look changes; they're safe from any thread (colors resolve while
/// drawing).
nonisolated public final class LookCenter: Observable, Sendable {
    public static let shared = LookCenter()

    private let registrar = ObservationRegistrar()
    private let stored = Mutex(Look.classic)

    init() {}

    /// The current look.
    public var look: Look {
        get {
            registrar.access(self, keyPath: \.look)
            return stored.withLock { $0 }
        }
        set {
            guard newValue != stored.withLock({ $0 }) else {
                return
            }
            registrar.withMutation(of: self, keyPath: \.look) {
                stored.withLock { $0 = newValue }
            }
        }
    }
}
