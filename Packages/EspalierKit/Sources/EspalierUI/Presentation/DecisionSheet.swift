// The decisions as sheets: Switch Branch's radio choices with an explicit
// default, and the editor's pop-up of the installed editors, with none
// chosen until the user picks one. The copy is the state layer's
// `Decision`.

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

/// The editor decision's sheet: the question, the installed editors'
/// pop-up, with none chosen until the user picks one, and the footnote.
struct EditorDecisionSheet: View {
    let decision: Decision
    let editors: [String]
    let onAnswer: (String?) -> Void
    @State private var selection: String?

    init(_ decision: Decision, editors: [String], selection: String? = nil, onAnswer: @escaping (String?) -> Void) {
        self.decision = decision
        self.editors = editors
        self.onAnswer = onAnswer
        _selection = State(initialValue: selection)
    }

    var body: some View {
        SheetScaffold(decision.title, message: decision.message) {
            Form {
                LabeledContent("Editor") {
                    CapsulePopUp("Editor", selection: $selection, title: selection ?? "Choose…") {
                        for name in editors {
                            MenuChoice(name, value: Optional(name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.columns)
        } buttons: {
            Text("You can change this in Settings ▸ Integrations.")
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.insetSmall)
            SheetButtons(decision.confirmButton, isConfirmDisabled: selection == nil, cancel: { onAnswer(nil) }) {
                onAnswer(selection)
            }
        }
    }
}

/// Shows the presenter's decisions.
@MainActor
enum DecisionHost {
    static let sheetID = "espalier.decision"

    static func present(_ pending: PendingDecision, in context: WindowContext) {
        let presenter = context.presenter
        let modals = context.modals
        let answer: (DecisionAnswer?) -> Void = { answer in
            presenter.respond(to: pending.id, with: answer)
            modals.dismissSheet(id: sheetID)
        }
        modals.presentSheet(id: sheetID, onDismiss: {
            presenter.respond(to: pending.id, with: nil)
        }) {
            switch pending.decision {
            case .uncommittedChanges:
                DecisionSheet(pending.decision) { strategy in
                    answer(strategy.map(DecisionAnswer.strategy))
                }
            case .externalEditor(let editors):
                EditorDecisionSheet(pending.decision, editors: editors) { name in
                    answer(name.map(DecisionAnswer.editor))
                }
            }
        }
    }
}
