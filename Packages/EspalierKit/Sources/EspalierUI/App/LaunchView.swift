// The window while Espalier launches, and when launching fails: nothing for
// 300 ms, then a centered spinner.

import SwiftUI

/// Launching: nothing for 300 ms, then a spinner.
struct LaunchView: View {
    var body: some View {
        DelayedProgressView()
    }
}

/// Launching failed (the bundled git or espalier-askpass is missing).
struct LaunchErrorView: View {
    let message: String

    var body: some View {
        CenteredMessage(
            "Espalier Couldn't Start",
            systemImage: "exclamationmark.triangle",
            description: message,
            tint: Color(espalier: Palette.warningMark),
            isLarge: true
        )
        .fillingSpace()
    }
}
