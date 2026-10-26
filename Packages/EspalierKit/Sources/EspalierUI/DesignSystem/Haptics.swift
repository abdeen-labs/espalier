// Espalier's trackpad feedback: a tap as a drag takes a new place to drop
// (between commits or onto one in History, a branch in the sidebar), and a
// tick as a dragged slider's knob reaches an end of its track. One per
// change, never while it rests there. AppKit plays it only on a Force Touch
// trackpad while it's touched.

import AppKit

/// Espalier's trackpad feedback.
enum Haptics {
    /// A drag taking a new place to drop.
    @MainActor
    static func dropTarget() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A dragged control reaching a stop: a slider's knob at an end.
    @MainActor
    static func stop() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
