// The Settings window's controls in DesignSystem, each in light and dark:
// the switch (on, off, and disabled), the pop-up drawn as a capsule field,
// the radio rows, and the capsule stepper.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Settings controls", .captures) @MainActor
struct SettingsControlCaptures {
    private let area = "Components"

    private enum Strategy: Hashable {
        case ask, bring, stash
    }

    @Test("the switch: on, off, and disabled each way, with and without its label")
    func switches() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetLarge) {
                Toggle("On", isOn: .constant(true))
                    .labelsHidden()
                Toggle("Off", isOn: .constant(false))
                    .labelsHidden()
                Toggle("On", isOn: .constant(true))
                    .labelsHidden()
                    .disabled(true)
                Toggle("Off", isOn: .constant(false))
                    .labelsHidden()
                    .disabled(true)
            }
            Toggle("Load environment variables from your shell", isOn: .constant(true))
                .frame(width: 320)
        }
        .toggleStyle(.capsuleSwitch)
        .padding(Metrics.insetLarge)
        capture(view, named: "switch", area: area)
    }

    @Test("the capsule pop-up: a choice, a long one cut short, disabled, and Settings' date format as wide as its widest choice, that one chosen")
    func popUps() {
        let dateTitles = DateFormatPattern.allCases.map { AppearanceSettings.formatTitle(example: $0.example, pattern: $0.rawValue) }
        let widest = AppearanceSettings.formatTitle(example: DateFormatPattern.longMonthOrdinalDayYear.example, pattern: DateFormatPattern.longMonthOrdinalDayYear.rawValue)
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                CapsulePopUp("Email", selection: .constant("joe@example.com"), title: "joe@example.com") {
                    MenuChoice("joe@example.com", value: "joe@example.com")
                    MenuChoice("Other", value: "other")
                }
                CapsulePopUp("Date format", selection: .constant(1), title: "Thursday, October 19, 2017 (EEEE, MMMM d, yyyy)") {
                    MenuChoice("Thursday, October 19, 2017 (EEEE, MMMM d, yyyy)", value: 1)
                }
                CapsulePopUp("Editor", selection: .constant(0), title: "None") {
                    MenuChoice("None", value: 0)
                }
                .disabled(true)
            }
            .frame(width: Metrics.SettingsWindow.controlWidth)
            CapsulePopUp("Date format", selection: .constant(widest), title: widest, fitting: dateTitles) {
                for title in dateTitles {
                    MenuChoice(title, value: title)
                }
            }
            .settingsControlWidthFittingChoices()
        }
        .padding(Metrics.insetLarge)
        capture(view, named: "capsulePopUp", area: area)
    }

    @Test("radio rows: the chosen one semibold, with and without descriptions")
    func radioList() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetLarge) {
            RadioList("Switching branches with changes", selection: .constant(Strategy.ask), choices: [
                ChoiceListItem("Ask me where my changes should go", value: .ask),
                ChoiceListItem("Always bring my changes to the new branch", value: .bring),
                ChoiceListItem("Always stash them on the current branch", value: .stash),
            ])
            RadioList("Base", selection: .constant(Strategy.bring), choices: [
                ChoiceListItem("Leave my changes on main", description: "Your in-progress work will be stashed on this branch.", value: .ask),
                ChoiceListItem("Bring my changes to feature/login", description: "Your in-progress work will follow you.", value: .bring),
            ])
            .disabled(true)
        }
        .frame(width: 420)
        .padding(Metrics.insetLarge)
        capture(view, named: "radioList", area: area)
    }

    @Test("the capsule stepper: in range, at its smallest, and disabled")
    func stepper() {
        let view = HStack(spacing: Metrics.insetLarge) {
            CapsuleStepper("Text size", value: "100%", decrement: {}, increment: {})
            CapsuleStepper("Text size", value: "67%", canDecrement: false, decrement: {}, increment: {})
            CapsuleStepper("Text size", value: "125%", decrement: {}, increment: {})
                .disabled(true)
        }
        .padding(Metrics.insetLarge)
        capture(view, named: "capsuleStepper", area: area)
    }
}
