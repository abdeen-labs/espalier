import EspalierCore
import GitKit
import Synchronization
import Testing

/// Responders for `PromptCenter`, which answer prompts in code.
public enum PromptResponder {
    /// Records an issue for every prompt and dismisses it: for tests where
    /// git must not ask anything.
    public static func failing(sourceLocation: SourceLocation = #_sourceLocation) -> PromptCenter.Responder {
        { prompt in
            Issue.record(Comment(rawValue: "Unexpected prompt: \(prompt)"), sourceLocation: sourceLocation)
            return prompt.cancelledAnswer
        }
    }

    /// Dismisses every prompt.
    public static var dismissing: PromptCenter.Responder {
        { prompt in prompt.cancelledAnswer }
    }

    /// Answers every prompt with `answer` (a prompt of another kind is
    /// dismissed).
    public static func always(_ answer: PromptAnswer) -> PromptCenter.Responder {
        { prompt in prompt.accepts(answer) ? answer : prompt.cancelledAnswer }
    }

    /// Answers failed hooks with `resolution`, recording an issue for
    /// anything else.
    public static func hookFailures(_ resolution: HookFailureResolution, sourceLocation: SourceLocation = #_sourceLocation) -> PromptCenter.Responder {
        { prompt in
            if case .hookFailed = prompt {
                return .hookFailure(resolution)
            }
            Issue.record(Comment(rawValue: "Unexpected prompt: \(prompt)"), sourceLocation: sourceLocation)
            return prompt.cancelledAnswer
        }
    }

    /// Answers prompts with `answers`, in order; a prompt past the end records
    /// an issue and is dismissed.
    public static func answering(_ answers: [PromptAnswer], sourceLocation: SourceLocation = #_sourceLocation) -> PromptCenter.Responder {
        let remaining = Mutex(answers)
        return { prompt in
            let answer = remaining.withLock { answers -> PromptAnswer? in
                answers.isEmpty ? nil : answers.removeFirst()
            }
            guard let answer else {
                Issue.record(Comment(rawValue: "Unexpected prompt: \(prompt)"), sourceLocation: sourceLocation)
                return prompt.cancelledAnswer
            }
            return answer
        }
    }
}
