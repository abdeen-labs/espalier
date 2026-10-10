// Ported from desktop/app/src/lib/stores/copilot-store.ts (runConflictResolutionTurn's reasoning buffer)

import EspalierSupport

/// Turns the model's streamed reasoning into whole sentences, so the UI can
/// show what the model is currently thinking about, one sentence at a time.
///
/// A sentence ends at `.`, `!`, or `?` followed by whitespace, or at a run of
/// newlines: `/(?<!\d)([.!?])\s+|\n+/`. A terminator right after a
/// digit doesn't count, so list markers like `1. ` don't split a sentence.
struct ReasoningSentenceSplitter {
    private var buffer: [Unicode.Scalar] = []

    /// Appends a reasoning increment; returns the sentences it completes.
    mutating func append(_ delta: String) -> [String] {
        buffer.append(contentsOf: delta.unicodeScalars)
        return flush(force: false)
    }

    /// Returns the complete sentences in the buffer and, when `force` is
    /// set, the remaining text too (if it isn't blank).
    mutating func flush(force: Bool) -> [String] {
        var sentences: [String] = []
        while let end = sentenceEnd() {
            let sentence = JSCompat.trim(String(String.UnicodeScalarView(buffer[..<end])))
            buffer.removeFirst(end)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        if force {
            let rest = JSCompat.trim(String(String.UnicodeScalarView(buffer)))
            if !rest.isEmpty {
                sentences.append(rest)
                buffer.removeAll()
            }
        }
        return sentences
    }

    /// The end of the first match of `/(?<!\d)([.!?])\s+|\n+/`, if any.
    private func sentenceEnd() -> Int? {
        for start in buffer.indices {
            let scalar = buffer[start]
            if scalar == "." || scalar == "!" || scalar == "?" {
                let afterDigit = start > 0 && JS.isASCIIDigit(buffer[start - 1])
                var end = start + 1
                while end < buffer.count, JSCompat.isWhitespace(buffer[end]) {
                    end += 1
                }
                if !afterDigit, end > start + 1 {
                    return end
                }
            } else if scalar == "\n" {
                var end = start + 1
                while end < buffer.count, buffer[end] == "\n" {
                    end += 1
                }
                return end
            }
        }
        return nil
    }
}
