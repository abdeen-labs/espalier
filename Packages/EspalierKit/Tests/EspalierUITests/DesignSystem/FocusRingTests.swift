// Espalier's focus ring on every control that takes keyboard focus, in
// light and dark: shown as if each had focus, since tests can't turn
// keyboard navigation on. And the AppKit checkbox, which draws the ring
// itself instead of the system's.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Focus rings") @MainActor
struct FocusRingTests {
    private let area = "Components"

    private enum Choice: Hashable {
        case one, two
    }

    @Test("every control's ring, in its own shape: buttons, menus, fields, toggles, lists, and the slider")
    func swiftUIControls() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetLarge) {
            HStack(spacing: Metrics.insetLarge) {
                Button("Quiet") {}
                    .buttonStyle(.quiet)
                Button("Prominent") {}
                    .buttonStyle(.prominent)
                Button("Cancel") {}
                    .buttonStyle(.secondary)
                Button {} label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.icon)
                Button {} label: {
                    Image(systemName: "lightbulb")
                }
                .buttonStyle(.smallIcon)
            }
            HStack(spacing: Metrics.insetLarge) {
                SplitCapsuleButton(.quiet, action: {}) {
                    Label("Fetch origin", systemImage: "arrow.triangle.2.circlepath")
                } menu: {
                    MenuAction("Pull") {}
                }
                PullDownButton("More Actions") {
                    MenuAction("Pull") {}
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.icon)
                CapsulePopUp("Editor", selection: .constant(0), title: "Xcode") {
                    MenuChoice("Xcode", value: 0)
                }
                .frame(width: 140)
            }
            HStack(spacing: Metrics.insetLarge) {
                Button {} label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.text3)
                }
                .buttonStyle(.bare(.circle))
                Button {} label: {
                    MonoChip("1a2b3c4")
                }
                .buttonStyle(.bare(.capsule))
                Button {} label: {
                    Text("Stashed Changes")
                        .padding(.horizontal, Metrics.insetSmall)
                        .frame(height: 28)
                }
                .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
                Button("Learn more") {}
                    .buttonStyle(.textLink)
            }
            HStack(spacing: Metrics.insetLarge) {
                CapsuleStepper("Text size", value: "100%", decrement: {}, increment: {})
                Toggle("Switch", isOn: .constant(true))
                    .toggleStyle(.capsuleSwitch)
                    .labelsHidden()
                Toggle("Checked", isOn: .constant(true))
                    .toggleStyle(.checkboxMark)
                Toggle("Unchecked", isOn: .constant(false))
                    .toggleStyle(.checkboxMark)
            }
            HStack(spacing: Metrics.insetLarge) {
                CapsuleSegmentedControl("Mode", selection: .constant(Choice.one), segments: [
                    CapsuleSegment("Simple", value: .one),
                    CapsuleSegment("Graph", value: .two),
                ])
                CapsuleSearchField("Filter", text: .constant(""))
                    .frame(width: 160)
                TextField("Name", text: .constant("feature/login"))
                    .textFieldStyle(.capsule)
                    .frame(width: 160)
            }
            ChoiceList("Base", selection: .constant(Choice.two), choices: [
                ChoiceListItem("Leave my changes on main", description: "Your in-progress work will be stashed on this branch.", value: .one),
                ChoiceListItem("Bring my changes to feature/login", description: "Your in-progress work will follow you.", value: .two),
            ])
            .frame(width: 420)
            RadioList("Strategy", selection: .constant(Choice.one), choices: [
                ChoiceListItem("Ask me where my changes should go", value: .one),
                ChoiceListItem("Always bring my changes to the new branch", value: .two),
            ])
            .frame(width: 420)
            CapsuleSlider("Opacity", value: .constant(0.4))
                .frame(width: 200)
        }
        .padding(Metrics.insetLarge)
        .environment(\.showsFocusRings, true)
        assertSnapshot(view, named: "focusRings", area: area)
    }

    @Test("the AppKit checkbox draws Espalier's ring around its box, never the system's")
    func appKitCheckbox() throws {
        let checkbox = CheckboxButton(title: "Include in commit", target: nil, action: nil)
        #expect(checkbox.focusRingType == .none)
        checkbox.frame = CGRect(x: 8, y: 6, width: 160, height: 20)
        #expect(checkbox.focusRingFrame == nil)
        checkbox.focusRingOverride = true
        let outset = Metrics.FocusRing.outset
        let frame = try #require(checkbox.focusRingFrame)
        #expect(frame.size == checkbox.boxRect.insetBy(dx: -outset, dy: -outset).size)
        #expect(frame.minX == checkbox.boxRect.minX - outset)
        checkbox.focusRingOverride = false
        #expect(checkbox.focusRingFrame == nil)
    }

    @Test("the AppKit checkbox's ring, on and off")
    func appKitCheckboxSnapshot() {
        for state in [NSControl.StateValue.on, .off] {
            assertSnapshot({
                let container = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: 32))
                let checkbox = CheckboxButton(title: "Include in commit", target: nil, action: nil)
                checkbox.state = state
                checkbox.frame = CGRect(x: 8, y: 6, width: 160, height: 20)
                checkbox.focusRingOverride = true
                container.addSubview(checkbox)
                return container
            }, named: state == .on ? "checkboxFocusRing-on" : "checkboxFocusRing-off", area: area, size: CGSize(width: 180, height: 32))
        }
    }
}
