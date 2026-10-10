@testable import AIKit
import Foundation
import Testing

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    @Test("picks the lowest supported effort, or the preferred one when supported")
    func supportedEfforts() {
        #expect(getLowestReasoningEffort(nil) == nil)
        #expect(getLowestReasoningEffort([]) == nil)
        #expect(getLowestReasoningEffort([.xhigh, .high]) == .high)
        #expect(getSupportedReasoningEffort([.low, .medium, .high], preferred: .medium) == .medium)
        #expect(getSupportedReasoningEffort([.high, .xhigh], preferred: .medium) == .high)
        #expect(getSupportedReasoningEffort(nil, preferred: .medium) == nil)
    }
}

@Suite("Reasoning sentences")
struct ReasoningSentenceSplitterTests {
    private func split(_ deltas: [String], force: Bool = true) -> [String] {
        var splitter = ReasoningSentenceSplitter()
        var sentences = deltas.flatMap { splitter.append($0) }
        if force {
            sentences += splitter.flush(force: true)
        }
        return sentences
    }

    @Test("ends sentences at terminators followed by whitespace, and at newlines")
    func terminators() {
        #expect(split(["One. Two! Three? Four"]) == ["One.", "Two!", "Three?", "Four"])
        #expect(split(["Line one\nLine two\n\n\nLine three"]) == ["Line one", "Line two", "Line three"])
    }

    @Test("doesn't split after a digit, or at a terminator without whitespace")
    func nonTerminators() {
        #expect(split(["1. First step 2. Second", " step. Done"]) == ["1. First step 2. Second step.", "Done"])
        #expect(split(["Version 2.0.1 is out.Really"]) == ["Version 2.0.1 is out.Really"])
    }

    @Test("waits for whitespace after a terminator that ends a delta")
    func waitsAcrossDeltas() {
        var splitter = ReasoningSentenceSplitter()
        #expect(splitter.append("Hello.") == [])
        #expect(splitter.append(" World") == ["Hello."])
        #expect(splitter.flush(force: false) == [])
        #expect(splitter.flush(force: true) == ["World"])
        #expect(splitter.flush(force: true) == [])
    }

    @Test("drops blank sentences and trims JavaScript whitespace")
    func blanks() {
        #expect(split(["\u{3000}\n\n  Real one.\u{A0} "]) == ["Real one."])
        #expect(split(["   "], force: true) == [])
    }
}

@Suite("Think tags")
struct ThinkTagSplitterTests {
    private func run(_ deltas: [String]) -> [AIStreamEvent] {
        var splitter = ThinkTagSplitter()
        return deltas.flatMap { splitter.process($0) } + splitter.finish()
    }

    @Test("separates a leading think block, even when its tags are split")
    func leadingBlock() {
        #expect(run(["<think>Plan</think>Answer"]) == [.reasoning("Plan"), .content("Answer")])
        #expect(run(["\n <th", "ink>Pl", "an</thi", "nk>", "Ans", "wer"]) == [.reasoning("Pl"), .reasoning("an"), .content("Ans"), .content("wer")])
    }

    @Test("leaves content without a leading think block alone")
    func noBlock() {
        #expect(run(["Hello <think>x</think>"]) == [.content("Hello <think>x</think>")])
        #expect(run(["<thin", "g>"]) == [.content("<thing>")])
        #expect(run(["<th"]) == [.content("<th")])
        #expect(run([]) == [])
    }

    @Test("treats an unclosed think block as reasoning")
    func unclosed() {
        #expect(run(["<think>still thinking"]) == [.reasoning("still t"), .reasoning("hinking")])
        #expect(ThinkTagSplitter.split(AIResponse(content: "<think>a</think>b", reasoning: "r")) == AIResponse(content: "b", reasoning: "r\n\na"))
        #expect(ThinkTagSplitter.split(AIResponse(content: "<think>unclosed")) == AIResponse(content: "", reasoning: "unclosed"))
    }
}
