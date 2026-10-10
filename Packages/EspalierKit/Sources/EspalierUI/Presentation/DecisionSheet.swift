// The Switch Branch decision, as a sheet of radio choices with an explicit
// default. The copy is the state layer's `Decision`.

import EspalierCore
import GitKit
import SwiftUI

/// A decision's sheet: the question, one radio row per choice (the first is
/// the default), the selected choice's warning, and the footnote.
public struct DecisionSheet: View {
    private let decision: Decision
    private let onAnswer: (UncommittedChangesStrategy?) -> Void
    @State private var selection: UncommittedChangesStrategy

    public init(_ decision: Decision, onAnswer: @escaping (UncommittedChangesStrategy?) -> Void) {
        self.decision = decision
        self.onAnswer = onAnswer
        _selection = State(initialValue: decision.choices.first?.strategy ?? .stashOnCurrentBranch)
    }

    public var body: some View {
        SheetScaffold(decision.title, message: decision.message) {
            ChoiceList(
                decision.message,
                selection: $selection,
                choices: decision.choices.map { ChoiceListItem($0.title, description: $0.description, value: $0.strategy) }
            )
            if let warning = selectedChoice?.warning {
                Label {
                    Text(warning)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    WarningGlyph()
                }
                .font(Typography.secondary)
            }
        } buttons: {
            Text("You can change this in Settings ▸ Prompts.")
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.insetSmall)
            SheetButtons(decision.confirmButton, cancel: { onAnswer(nil) }) {
                onAnswer(selection)
            }
        }
    }

    private var selectedChoice: DecisionChoice? {
        decision.choices.first { $0.strategy == selection }
    }
}

/// Shows the presenter's decisions.
@MainActor
enum DecisionHost {
    static let sheetID = "espalier.decision"

    static func present(_ pending: PendingDecision, in context: WindowContext) {
        let presenter = context.presenter
        let modals = context.modals
        modals.presentSheet(id: sheetID, onDismiss: {
            presenter.respond(to: pending.id, with: nil)
        }) {
            DecisionSheet(pending.decision) { strategy in
                presenter.respond(to: pending.id, with: strategy)
                modals.dismissSheet(id: sheetID)
            }
        }
    }
}
