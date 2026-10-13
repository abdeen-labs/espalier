// About Espalier, and its acknowledgements with the first component
// chosen, as the window opens: GitHub Desktop's notice.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("About", .captures, .hangGuard(minutes: 5)) @MainActor
struct AboutCaptures {
    private let area = "About"

    @Test("About Espalier")
    func about() {
        capture(AboutView(content: AboutContent(version: "1.0", build: "42")), named: "about", area: area)
    }

    @Test("Acknowledgements: the first component's notice")
    func acknowledgements() async {
        let size = CGSize(width: Metrics.About.acknowledgementsWidth, height: Metrics.About.acknowledgementsHeight)
        await captureSettled({ AcknowledgementsView() }, named: "acknowledgements", area: area, size: size)
    }
}
