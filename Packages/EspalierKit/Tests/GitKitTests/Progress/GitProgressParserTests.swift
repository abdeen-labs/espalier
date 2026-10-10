// Ported from desktop/app/test/unit/progress/git-test.ts

@testable import GitKit
import Testing
import TestSupport

@Suite("GitProgressParser")
struct GitProgressParserTests {
    @Test("requires at least one step")
    func requiresAStep() {
        #expect(throws: GitProgressParserError.self) {
            try GitProgressParser([])
        }
    }

    @Test("parses progress with one step")
    func oneStep() throws {
        var parser = try GitProgressParser([
            ProgressStep(title: "remote: Compressing objects", weight: 1),
        ])

        #expect(parser.parse("remote: Compressing objects:  72% (16/22)").percent == 16.0 / 22.0)
    }

    @Test("enforces ordering of steps")
    func enforcesOrdering() throws {
        var parser = try GitProgressParser([
            ProgressStep(title: "remote: Compressing objects", weight: 0.5),
            ProgressStep(title: "Receiving objects", weight: 0.5),
        ])

        var result = parser.parse("remote: Compressing objects:  72% (16/22)")

        #expect(result.isProgress)
        #expect(result.percent == 16.0 / 22.0 / 2)

        result = parser.parse("Receiving objects:  99% (166741/167587), 267.24 MiB | 2.40 MiB/s")

        #expect(result.isProgress)
        #expect(result.percent == 0.5 + 166741.0 / 167587.0 / 2)

        result = parser.parse("remote: Compressing objects:  72% (16/22)")

        #expect(!result.isProgress)
    }

    @Test("parses a line of progress", arguments: [
        NamedCase("parses progress with no total", (
            line: "remote: Counting objects: 167587",
            expected: GitProgressInfo(
                title: "remote: Counting objects",
                value: 167587,
                total: nil,
                percent: nil,
                done: false,
                text: "remote: Counting objects: 167587"
            )
        )),
        NamedCase("parses final progress with no total", (
            line: "remote: Counting objects: 167587, done.",
            expected: GitProgressInfo(
                title: "remote: Counting objects",
                value: 167587,
                total: nil,
                percent: nil,
                done: true,
                text: "remote: Counting objects: 167587, done."
            )
        )),
        NamedCase("parses progress with total", (
            line: "remote: Compressing objects:  72% (16/22)",
            expected: GitProgressInfo(
                title: "remote: Compressing objects",
                value: 16,
                total: 22,
                percent: 72,
                done: false,
                text: "remote: Compressing objects:  72% (16/22)"
            )
        )),
        NamedCase("parses final with total", (
            line: "remote: Compressing objects: 100% (22/22), done.",
            expected: GitProgressInfo(
                title: "remote: Compressing objects",
                value: 22,
                total: 22,
                percent: 100,
                done: true,
                text: "remote: Compressing objects: 100% (22/22), done."
            )
        )),
        NamedCase("parses with total and throughput", (
            line: "Receiving objects:  99% (166741/167587), 267.24 MiB | 2.40 MiB/s",
            expected: GitProgressInfo(
                title: "Receiving objects",
                value: 166741,
                total: 167587,
                percent: 99,
                done: false,
                text: "Receiving objects:  99% (166741/167587), 267.24 MiB | 2.40 MiB/s"
            )
        )),
        NamedCase("parses final with total and throughput", (
            line: "Receiving objects: 100% (167587/167587), 279.67 MiB | 2.43 MiB/s, done.",
            expected: GitProgressInfo(
                title: "Receiving objects",
                value: 167587,
                total: 167587,
                percent: 100,
                done: true,
                text: "Receiving objects: 100% (167587/167587), 279.67 MiB | 2.43 MiB/s, done."
            )
        )),
        NamedCase("does not parse things that aren't progress", (
            line: "remote: Total 167587 (delta 19), reused 11 (delta 11), pack-reused 167554         ",
            expected: nil
        )),
    ] as [NamedCase<(line: String, expected: GitProgressInfo?)>])
    func parsesLine(_ testCase: NamedCase<(line: String, expected: GitProgressInfo?)>) {
        #expect(GitProgressInfo.parse(testCase.value.line) == testCase.value.expected)
    }

    // MARK: - Espalier

    @Test("does not parse a line without a title")
    func noTitle() {
        // Not progress with an empty title: skipping the first two characters
        // would make "  42" and "ab42" read as 42.
        #expect(GitProgressInfo.parse("  42") == nil)
        #expect(GitProgressInfo.parse("ab42") == nil)
        #expect(GitProgressInfo.parse("xx50% (1/2)") == nil)
        #expect(GitProgressInfo.parse(": 42") == nil)
    }

    @Test("rejects malformed percentages")
    func malformedPercentages() {
        #expect(GitProgressInfo.parse("Receiving objects: 1000% (1/2)") == nil)
        #expect(GitProgressInfo.parse("Receiving objects: 10% (1/2) ") != nil)
        #expect(GitProgressInfo.parse("Receiving objects: 10% (1/2)x") == nil)
        #expect(GitProgressInfo.parse("Receiving objects: 10% (1 /2)") == nil)
        #expect(GitProgressInfo.parse("Receiving objects: \u{0661}0% (1/2)") == nil)
    }

    @Test("strips terminal escape codes before parsing")
    func stripsEscapes() throws {
        var parser = try GitProgressParser([ProgressStep(title: "Receiving objects", weight: 1)])

        let result = parser.parse("\u{1B}[1mReceiving objects:\u{1B}[0m  50% (1/2)")
        guard case .progress(let progress) = result else {
            Issue.record("Expected progress, got \(result)")
            return
        }
        #expect(progress.percent == 0.5)
        #expect(progress.details.text == "Receiving objects:  50% (1/2)")
    }

    @Test("strips the escape codes Node's stripVTControlCharacters strips")
    func stripVTControlCharactersMatchesNode() {
        // Expected values from Node 24's util.stripVTControlCharacters.
        #expect(stripVTControlCharacters("\u{1B}[31mred\u{1B}[0m \u{9B}1;2m x \u{1B}]0;title\u{07} y") == "red  x  y")
        #expect(stripVTControlCharacters("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(stripVTControlCharacters("plain text: 50% (1/2)") == "plain text: 50% (1/2)")
    }

    @Test("a parser whose steps weigh nothing reports zero, not NaN")
    func zeroWeights() throws {
        var parser = try GitProgressParser([ProgressStep(title: "Step", weight: 0)])
        let result = parser.parse("Step: 50% (1/2)")
        #expect(result.isProgress)
        #expect(result.percent == 0)
        #expect(parser.parse("Other").percent == 0)
    }
}

extension GitProgressResult {
    var isProgress: Bool {
        if case .progress = self {
            return true
        }
        return false
    }
}
