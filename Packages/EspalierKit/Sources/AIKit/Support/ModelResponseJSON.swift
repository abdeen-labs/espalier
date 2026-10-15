import EspalierSupport
import Foundation

private let jsonFenceLazy = JSCompat.regex("```json" + JSCompat.whitespace + #"*([\s\S]*?)```"#)
private let anyFenceLazy = JSCompat.regex("```" + JSCompat.whitespace + #"*([\s\S]*?)```"#)
private let jsonFenceGreedy = JSCompat.regex("```json" + JSCompat.whitespace + #"*([\s\S]*)```"#)
private let anyFenceGreedy = JSCompat.regex("```" + JSCompat.whitespace + #"*([\s\S]*)```"#)

/// The JSON value in a model's response, or `nil` when there's none.
///
/// Tries, in order: the first code block (```` ```json ```` before any
/// other), which handles the common single-block and multi-block cases;
/// everything from the first fence to the last, which handles triple
/// backticks inside the JSON's strings; and the whole response, for one
/// with no fences. The first that parses is the value.
func parseModelResponseJSON(_ content: String) -> JSONValue? {
    let nonGreedy = JSCompat.match(content, jsonFenceLazy) ?? JSCompat.match(content, anyFenceLazy)
    let greedy = JSCompat.match(content, jsonFenceGreedy) ?? JSCompat.match(content, anyFenceGreedy)

    var candidates: [String] = []
    let nonGreedyCandidate = nonGreedy.map { JSCompat.trim($0[1] ?? "") }
    if let nonGreedyCandidate {
        candidates.append(nonGreedyCandidate)
    }
    if let greedy {
        let greedyCandidate = JSCompat.trim(greedy[1] ?? "")
        if nonGreedyCandidate.map({ !JSCompat.strictEquals(greedyCandidate, $0) }) ?? true {
            candidates.append(greedyCandidate)
        }
    }
    candidates.append(JSCompat.trim(content))

    return candidates.lazy.compactMap { try? JSONValue.parse($0) }.first
}
