import EspalierSupport

/// Separates `<think>...</think>` reasoning that some local reasoning models
/// (DeepSeek R1 distills, Qwen 3, ...) write at the start of the message
/// content when an OpenAI-compatible server doesn't split it out into a
/// `reasoning_content` field. Without this, the commit message and conflict
/// resolution parsers would see the reasoning in front of the JSON.
///
/// Only a block at the very start of the content (after whitespace) counts;
/// `<think>` anywhere else is ordinary content.
struct ThinkTagSplitter {
    private enum State {
        /// Not enough content yet to tell whether it starts with `<think>`.
        case undecided
        case thinking
        case content
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var state = State.undecided
    private var pending = ""

    /// Feeds a content increment; returns the reasoning and content it
    /// resolves to, in order.
    mutating func process(_ delta: String) -> [AIStreamEvent] {
        switch state {
        case .content:
            return delta.isEmpty ? [] : [.content(delta)]

        case .undecided:
            pending += delta
            let candidate = String(String.UnicodeScalarView(pending.unicodeScalars.drop(while: JSCompat.isWhitespace)))
            if JSCompat.startsWith(candidate, Self.openTag) {
                state = .thinking
                pending = String(String.UnicodeScalarView(candidate.unicodeScalars.dropFirst(Self.openTag.unicodeScalars.count)))
                return drainThinking()
            }
            if JSCompat.startsWith(Self.openTag, candidate) {
                // Still a prefix of the tag (or only whitespace): wait for more.
                return []
            }
            state = .content
            defer { pending = "" }
            return [.content(pending)]

        case .thinking:
            pending += delta
            return drainThinking()
        }
    }

    /// Ends the content. Text still held back is released: as content if the
    /// tag never completed, as reasoning if the think block never closed.
    mutating func finish() -> [AIStreamEvent] {
        defer { pending = "" }
        guard !pending.isEmpty else {
            return []
        }
        switch state {
        case .thinking:
            return [.reasoning(pending)]
        case .undecided, .content:
            state = .content
            return [.content(pending)]
        }
    }

    private mutating func drainThinking() -> [AIStreamEvent] {
        let scalars = Array(pending.unicodeScalars)
        let close = Array(Self.closeTag.unicodeScalars)
        if let end = firstIndex(of: close, in: scalars) {
            let reasoning = String(String.UnicodeScalarView(scalars[..<end]))
            let rest = String(String.UnicodeScalarView(scalars[(end + close.count)...]))
            state = .content
            pending = ""
            var events: [AIStreamEvent] = []
            if !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if !rest.isEmpty {
                events.append(.content(rest))
            }
            return events
        }
        // Hold back enough to recognize a closing tag split across increments.
        let keep = min(scalars.count, close.count - 1)
        let emit = String(String.UnicodeScalarView(scalars[..<(scalars.count - keep)]))
        pending = String(String.UnicodeScalarView(scalars[(scalars.count - keep)...]))
        return emit.isEmpty ? [] : [.reasoning(emit)]
    }

    private func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard haystack.count >= needle.count else {
            return nil
        }
        return (0...(haystack.count - needle.count)).first { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

extension ThinkTagSplitter {
    /// Splits a complete response's content.
    static func split(_ response: AIResponse) -> AIResponse {
        var splitter = ThinkTagSplitter()
        let events = splitter.process(response.content) + splitter.finish()
        var content = ""
        var thinking = ""
        for event in events {
            switch event {
            case .content(let text):
                content += text
            case .reasoning(let text):
                thinking += text
            }
        }
        let reasoning = [response.reasoning, thinking].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return AIResponse(content: content, reasoning: reasoning, stopReason: response.stopReason)
    }
}
