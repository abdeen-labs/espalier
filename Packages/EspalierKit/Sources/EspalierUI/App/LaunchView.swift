// The window while Espalier launches, and when launching fails: nothing for
// 300 ms, then a centered spinner. Until the spinner, the window is
// transparent, so a quick launch never shows it empty. The window appears
// at once, with the spinner or with what launching loaded, and what
// replaces a spinner crossfades in over 0.22 s.

import AppKit
import SwiftUI

/// Launching: nothing for 300 ms, then a spinner. Until the spinner shows,
/// the window is transparent: it appears with what launching loaded, or
/// with the spinner when launching takes longer.
struct LaunchView: View {
    @State private var isSpinnerShown = false

    var body: some View {
        Group {
            if isSpinnerShown {
                ArcProgress(.large)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowTransparency(isTransparent: !isSpinnerShown))
        .task {
            try? await Task.sleep(for: Timing.spinnerDelay)
            isSpinnerShown = true
        }
    }
}

/// Keeps the window it's in transparent while `isTransparent`, and makes it
/// opaque once it isn't or the view leaves the window.
private struct WindowTransparency: NSViewRepresentable {
    let isTransparent: Bool

    func makeNSView(context: Context) -> WindowTransparencyView {
        let view = WindowTransparencyView()
        view.isTransparent = isTransparent
        return view
    }

    func updateNSView(_ view: WindowTransparencyView, context: Context) {
        view.isTransparent = isTransparent
    }
}

/// Makes the window transparent as the view moves into it, before the
/// window first shows, and opaque again once what replaces it has drawn.
private final class WindowTransparencyView: NSView {
    var isTransparent = true {
        didSet {
            if isTransparent != oldValue, let window {
                apply(to: window)
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window, window !== newWindow {
            if !isTransparent {
                // The spinner shows: what replaces it crossfades in.
                window.crossfadeContents(Motion.arrive)
            }
            reveal(window)
        }
        if let newWindow {
            apply(to: newWindow)
        }
    }

    private func apply(to window: NSWindow) {
        if isTransparent {
            window.alphaValue = 0
        } else {
            reveal(window)
        }
    }

    /// Makes `window` opaque on the run loop's next turn, after this turn's
    /// drawing, unless the view is keeping it transparent again by then.
    private func reveal(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window else {
                return
            }
            if let self, self.isTransparent, self.window === window {
                return
            }
            window.alphaValue = 1
        }
    }
}

/// Launching failed (the bundled git or espalier-askpass is missing).
struct LaunchErrorView: View {
    let message: String

    var body: some View {
        CenteredMessage(
            "Couldn't Start",
            systemImage: "exclamationmark.triangle",
            description: message,
            tint: Color(espalier: Palette.warningMark),
            isLarge: true
        )
        .fillingSpace()
    }
}
