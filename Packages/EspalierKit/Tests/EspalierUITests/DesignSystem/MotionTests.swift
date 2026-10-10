// Espalier's motion. The one answer to "animate?" (never with Reduce Motion,
// never where snapshots suppress it), and what an action during an
// animation does: Undo on a leaving toast runs once.

import EspalierCore
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Motion", .hangGuard(minutes: 5)) @MainActor
struct MotionTests {
    @Test("animate? never with Reduce Motion, never where motion is suppressed")
    func answer() {
        #expect(Motion.allows(reduceMotion: false, isSuppressed: false))
        #expect(!Motion.allows(reduceMotion: true, isSuppressed: false))
        #expect(!Motion.allows(reduceMotion: false, isSuppressed: true))
        #expect(!Motion.allows(reduceMotion: true, isSuppressed: true))

        // SwiftUI's policy: no animation at all with Reduce Motion, hover
        // and press included.
        let reduced = MotionPolicy(reduceMotion: true)
        #expect(!reduced.animates)
        #expect(reduced.animation(Motion.arrive) == nil)
        #expect(reduced.hover(true) == nil && reduced.hover(false) == nil)
        #expect(reduced.press(false) == nil)
        #expect(MotionPolicy(isSuppressed: true).animation(Motion.leave) == nil)

        let full = MotionPolicy()
        #expect(full.animation(Motion.arrive) == Motion.animation(Motion.arrive))
        #expect(full.hover(true) == Motion.animation(Motion.hoverIn))
        #expect(full.hover(false) == Motion.animation(Motion.hoverOut))
        // A press shows at once and eases back.
        #expect(full.press(true) == nil)
        #expect(full.press(false) == Motion.animation(Motion.pressRelease))
    }

    @Test("Undo clicked again while its toast leaves runs once")
    func undoDuringExit() async {
        let presenter = WindowPresenter()
        let runs = RunCounter()
        let toast = Toast("Committed", undo: ToastAction { runs.count += 1 })
        presenter.show(toast)
        let view = TimedToast(toast: toast, presenter: presenter)

        // The first click closes the toast; it stays on screen while it
        // leaves, and a second click lands on it.
        view.undo()
        #expect(presenter.toasts.isEmpty)
        view.undo()
        await waitUntil { runs.count > 0 }
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(runs.count == 1)
        #expect(presenter.takeToastUndo(toast.id) == nil)
    }
}

/// How many times an action ran.
@MainActor @Observable
private final class RunCounter {
    var count = 0
}
