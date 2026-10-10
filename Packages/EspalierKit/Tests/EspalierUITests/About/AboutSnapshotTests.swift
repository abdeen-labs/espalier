// About Espalier and its acknowledgements, in light. The other notices and
// the command line tool's alerts are AboutTests'.

import AppKit
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("About snapshots", .hangGuard(minutes: 5)) @MainActor
struct AboutSnapshotTests {
    private let area = "About"

    @Test("About Espalier")
    func about() {
        assertSnapshot(AboutView(content: AboutContent(version: "1.0", build: "42")), named: "about", area: area, appearances: [.light])
    }

    @Test("Acknowledgements: GitHub Desktop's notice")
    func acknowledgements() {
        let size = CGSize(width: Metrics.About.acknowledgementsWidth, height: Metrics.About.acknowledgementsHeight)
        assertSnapshot(AcknowledgementsView(selection: "desktop"), named: "acknowledgements", area: area, size: size, appearances: [.light])
    }
}
