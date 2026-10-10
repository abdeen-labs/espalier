// Ported from desktop/app/src/lib/progress/fetch.ts

/// Highly approximate (some would say outright inaccurate) division
/// of the individual progress reporting steps in a fetch operation
private let steps = [
    ProgressStep(title: "remote: Compressing objects", weight: 0.1),
    ProgressStep(title: "Receiving objects", weight: 0.7),
    ProgressStep(title: "Resolving deltas", weight: 0.2),
]

/// A utility for interpreting the output from `git fetch --progress`
/// and turning that into a percentage value estimating the overall progress
/// of the fetch.
public struct FetchProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
