// Views that finish what they show after they appear (an `onAppear`, a
// `.task`, a build off the main actor, AppKit's next layout pass): each is
// hosted on an offscreen window that stays up while that work runs, then
// drawn. The stage waits by suspending, so the main actor runs that work
// meanwhile. Staged captures draw in the run's look: a task's own look
// (`Look.with`) doesn't span a wait.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

/// A view on an offscreen window, kept up until it settles.
@MainActor
final class SettlingStage {
    let window: CaptureWindow
    /// The window's content: the hosting view.
    let content: NSView

    /// Hosts a SwiftUI view, as `Capture.render` does: at `size`, else at
    /// its fitting size.
    init(_ view: some View, size: CGSize? = nil, appearance: CaptureAppearance) {
        _ = Capture.look
        let host = NSHostingView(rootView: Capture.prepared(view).background(Color(nsColor: Palette.background)))
        // The stage keeps its size while the view changes: the host doesn't
        // size the window to its content.
        host.sizingOptions = []
        window = CaptureWindow(
            contentRect: CGRect(origin: .zero, size: size ?? CGSize(width: 400, height: 300)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.appearance
        window.contentView = host
        let fitting = size ?? host.fittingSize
        let bounds = CGRect(origin: .zero, size: CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        window.setContentSize(bounds.size)
        host.frame = bounds
        content = host
        content.layoutSubtreeIfNeeded()
    }

    /// Lays the view out, lets the main actor run what its layout started
    /// (an `onAppear`'s state, a `.task`), and lays it out again, `turns`
    /// times.
    func settle(turns: Int = 3) async {
        for _ in 0..<turns {
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            await Task.yield()
        }
        content.layoutSubtreeIfNeeded()
    }

    /// Settles, then waits until `condition` holds of what's laid out,
    /// looking again each time the main run loop has handled its work (AppKit
    /// views have nothing to observe).
    func settle(until condition: @escaping @MainActor () -> Bool) async {
        await settle()
        let content = content
        await waitUntilRunLoopIdle {
            content.layoutSubtreeIfNeeded()
            return condition()
        }
        await settle()
    }

    /// Waits until what the window draws stops changing: for work that
    /// leaves nothing to observe (a view's own state set from a task off
    /// the main actor). Motion is off, so a view that has settled draws the
    /// same twice.
    func settleUntilStill() async {
        var last = image.tiffRepresentation
        while true {
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                return
            }
            await settle(turns: 1)
            let next = image.tiffRepresentation
            if next == last {
                return
            }
            last = next
        }
    }

    /// What the window draws now.
    var image: NSBitmapImageRep {
        content.layoutSubtreeIfNeeded()
        return Capture.image(of: content)
    }

    /// Takes the view off its window: its `onDisappear` runs, and its tasks
    /// are cancelled.
    func close() {
        window.contentView = nil
    }

    /// Every view of `type` in the window's content, depth first.
    func views<V: NSView>(_ type: V.Type) -> [V] {
        content.captureDescendants(type)
    }
}

/// Captures a view that finishes what it shows after it appears, made anew
/// for each appearance: hosted, settled until `condition` holds of its
/// stage (and, when `untilStill`, until it stops changing), and drawn.
@MainActor
func captureSettled(
    _ makeView: () -> some View,
    named name: String,
    area: String,
    size: CGSize? = nil,
    appearances: [CaptureAppearance] = CaptureAppearance.allCases,
    untilStill: Bool = false,
    until condition: @escaping @MainActor (SettlingStage) -> Bool = { _ in true },
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for appearance in appearances {
        let stage = SettlingStage(makeView(), size: size, appearance: appearance)
        await stage.settle { condition(stage) }
        if untilStill {
            await stage.settleUntilStill()
        }
        let image = stage.image
        stage.close()
        capture(named: name, area: area, appearances: [appearance], sourceLocation: sourceLocation) { _ in image }
    }
}
