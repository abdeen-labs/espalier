// The checkbox and the centered message, in light and dark: the checkbox
// off, on, and mixed, enabled, disabled, and titled, as AppKit draws it and
// as SwiftUI does; and the centered message at a place's size and a pane's.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Checkbox and centered message") @MainActor
struct CheckboxSnapshotTests {
    private let area = "Components"

    @Test("checkboxes: off, on, and mixed; disabled; titled; AppKit and SwiftUI")
    func checkboxes() {
        let states: [Bool?] = [false, true, nil]
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetMedium) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, value in
                    InclusionCheckbox(value: value) { _ in }
                }
                ForEach(Array(states.enumerated()), id: \.offset) { _, value in
                    InclusionCheckbox(value: value, isEnabled: false) { _ in }
                }
            }
            HStack(spacing: Metrics.insetMedium) {
                ForEach(CheckboxState.allCases, id: \.self) { state in
                    CheckboxMark(state)
                }
                ForEach(CheckboxState.allCases, id: \.self) { state in
                    CheckboxMark(state)
                        .disabled(true)
                }
            }
            InclusionCheckbox(value: nil, title: "7 changed files", titleFont: ChangesHeader.titleFont) { _ in }
                .fixedSize()
        }
        .padding(Metrics.insetLarge)
        .background(Color(espalier: Palette.background))
        assertSnapshot(view, named: "checkboxes", area: area)
    }

    @Test("the centered message: a place's, with actions, and a pane's")
    func centeredMessage() {
        let view = HStack(alignment: .top, spacing: 0) {
            CenteredMessage(
                "No Local Changes",
                systemImage: "checkmark",
                description: "You have 2 local commits waiting to be pushed to GitHub.",
                tint: Color(espalier: Palette.success),
                isLarge: true
            ) {
                Button("Push origin") {}
                    .buttonStyle(.prominent)
                    .controlSize(.small)
            }
            .frame(width: 360)
            Hairline(.vertical)
            CenteredMessage(
                "This diff is too large to show automatically.",
                systemImage: "doc.text.magnifyingglass",
                description: "You can show it anyway, but Espalier may slow down."
            ) {
                Button("Show Diff") {}
                    .buttonStyle(.quiet)
            }
            .frame(width: 320)
        }
        .padding(.vertical, Metrics.insetLarge)
        .background(Color(espalier: Palette.background))
        assertSnapshot(view, named: "centeredMessage", area: area)
    }
}
