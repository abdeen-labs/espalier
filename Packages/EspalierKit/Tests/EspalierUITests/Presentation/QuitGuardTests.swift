// The quit guard's unfinished-message question: its setting, and when the
// alert offers "Do not show this message again".

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Quit guard", .offline, .hangGuard(minutes: 5)) @MainActor
struct QuitGuardTests {
    @Test("an unfinished message asks while the setting is on, and nothing asks once it's off")
    func setting() async throws {
        let fixture = try await makeOperationsFixture()
        fixture.repository.commit.draft.summary = "Unfinished"
        #expect(QuitGuard.reasons(fixture.app).repositoriesWithUnfinishedMessages.count == 1)

        fixture.app.preferences.confirmQuitWithUnfinishedMessage = false
        let reasons = QuitGuard.reasons(fixture.app)
        #expect(reasons.isEmpty)
        #expect(reasons.alert(defaultNumberFormat) == nil)
        await fixture.settle()
    }

    @Test("the alert offers the checkbox only when a commit message is all there is to lose", arguments: [
        NamedCase("message only", (operation: OperationKind?.none, messages: ["espalier"], offers: true)),
        NamedCase("message and a rebase", (operation: OperationKind?.some(.rebase), messages: ["espalier"], offers: false)),
        NamedCase("rebase only", (operation: OperationKind?.some(.rebase), messages: [String](), offers: false)),
    ])
    func checkbox(_ testCase: NamedCase<(operation: OperationKind?, messages: [String], offers: Bool)>) throws {
        let reasons = QuitGuardReasons(runningOperation: testCase.value.operation, repositoriesWithUnfinishedMessages: testCase.value.messages)
        let alert = try #require(reasons.alert(defaultNumberFormat))
        #expect((alert.suppressionTitle != nil) == testCase.value.offers)
    }
}
