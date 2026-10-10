// Ported from desktop/app/test/unit/copilot-conflict-resolution-model-test.ts

@testable import AIKit
import Testing

private let byokProvider = BYOKProvider(
    id: "provider-1",
    name: "My Provider",
    type: .openai,
    baseUrl: "https://api.example.com/v1",
    authKind: .apiKey,
    models: [BYOKModel(id: "custom-a", name: "Custom A (Deep reasoning)", reasoningEffort: .high)]
)

private let otherProvider = BYOKProvider(
    id: "provider-2",
    name: "Local",
    type: .openai,
    baseUrl: "http://localhost:11434/v1",
    authKind: .none,
    models: [BYOKModel(id: "plain", name: "Plain")]
)

@Suite("getConflictResolutionModelDisplay")
struct ConflictResolutionModelTests {
    // Adapted from "falls back to the default model and effort when nothing
    // is selected": with no built-in default, the only configured model is
    // used.
    @Test("uses the only configured model when nothing is selected")
    func onlyModelWhenNothingSelected() {
        #expect(
            getConflictResolutionModelDisplay(nil, providers: [byokProvider])
                == ConflictResolutionModelDisplay(modelName: "Custom A (Deep reasoning)", reasoningEffort: .high)
        )
        #expect(getConflictResolutionModelDisplay(nil, providers: []) == nil)
        #expect(getConflictResolutionModelDisplay(nil, providers: [byokProvider, otherProvider]) == nil)
    }

    @Test("shows BYOK model names verbatim and passes through the effort")
    func verbatimNames() {
        let selection = encodeModelKey(AIModelKey(providerId: "provider-1", modelId: "custom-a"))
        // Names are user-provided, so the "(Deep reasoning)" marker is kept.
        #expect(
            getConflictResolutionModelDisplay(selection, providers: [byokProvider, otherProvider])
                == ConflictResolutionModelDisplay(modelName: "Custom A (Deep reasoning)", reasoningEffort: .high)
        )
    }

    // Adapted from "falls back to the default model when the BYOK selection
    // is missing": a missing selection resolves only when one model is
    // configured, never to a provider the user didn't choose among several.
    @Test("falls back to the only configured model when the BYOK selection is missing")
    func missingSelection() {
        let selection = encodeModelKey(AIModelKey(providerId: "deleted", modelId: "gone"))
        #expect(
            getConflictResolutionModelDisplay(selection, providers: [byokProvider])
                == ConflictResolutionModelDisplay(modelName: "Custom A (Deep reasoning)", reasoningEffort: .high)
        )
        #expect(getConflictResolutionModelDisplay(selection, providers: [byokProvider, otherProvider]) == nil)
    }
}
