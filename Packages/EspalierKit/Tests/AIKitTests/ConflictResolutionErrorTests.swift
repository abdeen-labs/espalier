// Ported from desktop/app/test/unit/copilot-conflict-resolution-error-test.ts

@testable import AIKit
import Foundation
import Testing

private struct TestError: Error, Equatable {
    let message: String
}

@Suite("AIConflictResolutionError")
struct ConflictResolutionErrorTests {
    @Test("creates a sanitized failure with stable metadata")
    func sanitized() throws {
        let original = TestError(message: "Provider rejected secret for repository /private/repository")
        let failure = AIConflictResolutionError(original, stage: .streamResponse)

        #expect(failure.message == "AI Conflict Resolution Error: stage=stream-response, retryState=not-retried")
        #expect(failure.localizedDescription == failure.message)
        #expect(failure.stage == .streamResponse)
        #expect(failure.retryState == .notRetried)
        #expect(try #require(failure.underlyingError as? TestError) == original)
        #expect(!failure.message.contains("/private/repository"))
    }

    @Test("preserves existing structured failures at propagation boundaries")
    func preservesExisting() {
        let failure = AIConflictResolutionError(TestError(message: "Client failed"), stage: .createClient)
        let propagated = AIConflictResolutionError.wrapping(failure, stage: .unknown)

        #expect(propagated.stage == .createClient)
        #expect((propagated.underlyingError as? TestError)?.message == "Client failed")

        let wrapped = AIConflictResolutionError.wrapping(TestError(message: "Other"), stage: .processResult)
        #expect(wrapped.stage == .processResult)
    }
}
