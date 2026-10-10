// Ported from desktop/app/test/unit/progress/clone-test.ts

import GitKit
import Testing

@Suite("CloneProgressParser")
struct CloneProgressParserTests {
    // Each test makes its own parser.
    @Suite("#parse")
    struct Parse {
        @Test("understands relative weights")
        func relativeWeights() {
            var parser = CloneProgressParser()
            let compressing = parser.parse("remote: Compressing objects:  45% (10/22)")
            #expect(compressing.isProgress)
            #expect(compressing.percent == (10.0 / 22.0) * 0.1)

            let receiving = parser.parse("Receiving objects:  17% (4808/28282), 3.30 MiB | 1.29 MiB/s")
            #expect(receiving.isProgress)
            #expect(receiving.percent == 0.1 + (4808.0 / 28282.0) * 0.6)

            let resolving = parser.parse("Resolving deltas:  89% (18063/20263)")
            #expect(resolving.isProgress)
            #expect(resolving.percent == 0.7 + (18063.0 / 20263.0) * 0.1)

            let checkingOut = parser.parse("Checking out files: 100% (579/579)")
            #expect(checkingOut.isProgress)
            #expect(checkingOut.percent == 0.8 + (579.0 / 579.0) * 0.2)
        }

        @Test("ignores wrong order")
        func wrongOrder() {
            var parser = CloneProgressParser()
            let finalProgress = parser.parse("Checking out files: 100% (579/579)")
            let earlyProgress = parser.parse("Receiving objects:   1% (283/28282)")

            #expect(!earlyProgress.isProgress)
            #expect(finalProgress.isProgress)
        }

        @Test("ignores lines it doesn't understand")
        func ignoresUnknownLines() {
            var parser = CloneProgressParser()
            #expect(!parser.parse("Counting objects: 28282, done.").isProgress)
        }

        // MARK: - Espalier

        @Test("understands updating files, which current git prints instead of checking out files")
        func updatingFiles() {
            var parser = CloneProgressParser()
            _ = parser.parse("Resolving deltas: 100% (20263/20263), done.")
            let updating = parser.parse("Updating files:  50% (300/600)")
            #expect(updating.isProgress)
            #expect(abs(updating.percent - 0.9) < 1e-12)
        }
    }
}

@Suite("Progress parsers for current git")
struct CurrentGitProgressTitleTests {
    private func isClose(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1e-12
    }

    @Test("checkout progress understands updating files")
    func checkout() {
        var parser = CheckoutProgressParser()
        let result = parser.parse("Updating files:  25% (1/4)")
        #expect(result.isProgress)
        #expect(result.percent == 0.25)
        #expect(parser.parse("Checking out files: 100% (4/4)").percent == 1)
    }

    @Test("pull progress understands updating files")
    func pull() {
        var parser = PullProgressParser()
        let result = parser.parse("Updating files: 100% (4/4), done.")
        #expect(result.isProgress)
        #expect(isClose(result.percent, 1))
    }

    @Test("revert progress reports every line as context")
    func revert() {
        var parser = RevertProgressParser()
        #expect(!parser.parse("[main 62614ec] Revert \"rm\"").isProgress)
        #expect(!parser.parse(" 2 files changed, 2 insertions(+)").isProgress)
        #expect(parser.parse("  42").percent == 0)
    }
}
