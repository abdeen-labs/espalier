@testable import AIKit
import EspalierSupport
import Foundation

/// One scripted model turn: the increments to stream, then the response.
struct ScriptedTurn: Sendable {
    var events: [AIStreamEvent] = []
    var response: AIResponse

    static func content(_ content: String, reasoning: [String] = []) -> ScriptedTurn {
        ScriptedTurn(
            events: reasoning.map(AIStreamEvent.reasoning) + [.content(content)],
            response: AIResponse(content: content, reasoning: reasoning.joined())
        )
    }
}

/// A provider that answers from a script, for testing the features without
/// HTTP.
final class ScriptedProvider: AIProvider {
    let configuration = AIProviderConfiguration(
        name: "Scripted",
        type: .openai,
        baseUrl: "https://scripted.test/v1",
        credential: .none
    )

    private let handler: @Sendable (AIRequest) async throws -> ScriptedTurn
    private let recorded = Locked([AIRequest]())

    init(_ handler: @escaping @Sendable (AIRequest) async throws -> ScriptedTurn) {
        self.handler = handler
    }

    var requests: [AIRequest] {
        recorded.withLock { $0 }
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        recorded.withLock { $0.append(request) }
        return try await handler(request).response
    }

    func stream(_ request: AIRequest, onEvent: @escaping @Sendable (AIStreamEvent) -> Void) async throws -> AIResponse {
        recorded.withLock { $0.append(request) }
        let turn = try await handler(request)
        turn.events.forEach(onEvent)
        return turn.response
    }
}

private let fileHeading = JSCompat.regex(#"^## File: (.+?)( \(delete-vs-modify conflict\))?\z"#)
private let conflictHeading = JSCompat.regex(#"^### Conflict [0-9]+ of ([0-9]+)\z"#)

/// The files in a conflict resolution prompt, with their hunk counts (nil
/// for delete-vs-modify conflicts).
func promptFiles(_ prompt: String) -> [(path: String, hunks: Int?)] {
    var files: [(path: String, hunks: Int?)] = []
    for line in prompt.components(separatedBy: "\n") {
        if let match = JSCompat.match(line, fileHeading), let path = match[1] {
            files.append((path, match[2] == nil ? 0 : nil))
        } else if let match = JSCompat.match(line, conflictHeading), let count = match[1].flatMap({ Int($0) }),
                  !files.isEmpty, files[files.count - 1].hunks != nil
        {
            files[files.count - 1].hunks = count
        }
    }
    return files
}

/// A valid model response resolving every file in a prompt: each hunk
/// becomes `resolved <path> <n>`, each delete-vs-modify conflict is kept.
func resolvingEverything(_ prompt: String, summary: String? = "### Conflicting changes\nA.\n\n### Resolution\nB.") -> String {
    let resolutions: [JSONValue] = promptFiles(prompt).map { file in
        guard let hunks = file.hunks else {
            return ["path": .string(file.path), "action": "keep", "hunks": [], "reasoning": "Kept it."]
        }
        return [
            "path": .string(file.path),
            "hunks": .array((0..<hunks).map { ["resolvedContent": .string("resolved \(file.path) \($0)")] }),
            "reasoning": "Merged both sides.",
        ]
    }
    var object: JSONObject = ["resolutions": .array(resolutions), "references": []]
    if let summary {
        object["summary"] = .string(summary)
    }
    return String(decoding: JSONValue.object(object).serialized(), as: UTF8.self)
}

/// A conflicted file with `hunks` conflicts, ready for resolution.
func conflictedFile(_ path: String, hunks: Int = 1) -> FileConflictContext {
    let raw = (0..<hunks).map { "line \($0)\n<<<<<<< HEAD\nours \($0)\n=======\ntheirs \($0)\n>>>>>>> feature" }
        .joined(separator: "\n") + "\nend"
    return FileConflictContext(path: path, hunks: extractConflictHunks(raw), rawContent: raw)
}

/// A model request for the scripted provider.
func scriptedModel(timeout: Duration? = nil, effort: ReasoningEffort? = nil) -> AIModelRequest {
    AIModelRequest(
        modelId: "scripted-model",
        provider: AIProviderConfiguration(name: "Scripted", type: .openai, baseUrl: "https://scripted.test/v1", credential: .none),
        reasoningEffort: effort,
        timeout: timeout
    )
}
