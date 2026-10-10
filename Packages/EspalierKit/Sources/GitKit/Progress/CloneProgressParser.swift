// Ported from desktop/app/src/lib/progress/clone.ts

/// Highly approximate (some would say outright inaccurate) division
/// of the individual progress reporting steps in a clone operation
private let steps = [
    ProgressStep(title: "remote: Compressing objects", weight: 0.1),
    ProgressStep(title: "Receiving objects", weight: 0.6),
    ProgressStep(title: "Resolving deltas", weight: 0.1),
    // Current git says "Updating files"; older git says "Checking out files".
    ProgressStep(title: "Checking out files", weight: 0.2, alternativeTitles: ["Updating files"]),
]

/// A utility for interpreting the output from `git clone --progress`
/// and turning that into a percentage value estimating the overall progress
/// of the clone.
public struct CloneProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
