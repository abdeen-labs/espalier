// Espalier's focus ring on the controls that take keyboard focus without
// keyboard navigation, in light and dark: the capsule field and the search
// field, each given focus in a window of its own, stacked.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Focus rings", .captures) @MainActor
struct FocusRingCaptures {
    private let area = "Components"

    @Test("the fields' rings: the capsule field and the search field, focused")
    func fields() {
        let fields: [AnyView] = [
            AnyView(TextField("Name", text: .constant("feature/login"))
                .textFieldStyle(.capsule)
                .frame(width: 160)),
            AnyView(CapsuleSearchField("Filter", text: .constant(""))
                .frame(width: 160)),
        ]
        capture(named: "focusRings", area: area) { appearance in
            let images = fields.map { field in
                Capture.render(field.padding(Metrics.insetLarge), appearance: appearance) { host in
                    guard let textField = host.captureDescendants(NSTextField.self).first else {
                        Issue.record("The field has no text field to focus")
                        return
                    }
                    host.window?.makeFirstResponder(textField)
                }
            }
            return DesignCapture.stacked(images, appearance: appearance)
        }
    }
}
