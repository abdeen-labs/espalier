// Capturing History's views over a real repository: the view is hosted in
// a capture window in each appearance and drawn once what it builds on its
// own has landed (a diff's rows are built off the main actor).

import AppKit
import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

/// Hosts `view` at `size` in a capture window in each appearance, waits
/// until `isReady` holds for the host (and every diff in it shows its
/// document), and captures it in the run's look.
@MainActor
func captureLoaded(
    _ view: some View,
    named name: String,
    area: String,
    size: CGSize,
    until isReady: @escaping @MainActor (NSView) -> Bool = { _ in true },
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    // The run's look is the process's from here on, so what the view
    // builds while it loads draws in it too.
    _ = Capture.look
    for appearance in CaptureAppearance.allCases {
        let root = Capture.prepared(view)
            .background(Color(nsColor: Palette.background))
        let host = NSHostingView(rootView: root)
        let window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        await waitUntilRunLoopIdle {
            host.layoutSubtreeIfNeeded()
            return isReady(host) && diffsShowTheirDocuments(in: host)
        }
        host.layoutSubtreeIfNeeded()
        Capture.write(Capture.image(of: host), named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
        window.contentView = nil
    }
}
