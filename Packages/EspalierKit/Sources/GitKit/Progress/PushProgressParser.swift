// Ported from desktop/app/src/lib/progress/push.ts

/// Highly approximate (some would say outright inaccurate) division
/// of the individual progress reporting steps in a push operation
private let steps = [
    ProgressStep(title: "Compressing objects", weight: 0.2),
    ProgressStep(title: "Writing objects", weight: 0.7),
    ProgressStep(title: "remote: Resolving deltas", weight: 0.1),
]

/// A utility for interpreting the output from `git push --progress`
/// and turning that into a percentage value estimating the overall progress
/// of the push.
public struct PushProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
