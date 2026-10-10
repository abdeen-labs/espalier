// Ported from desktop/app/src/lib/progress/pull.ts

/// Highly approximate (some would say outright inaccurate) division
/// of the individual progress reporting steps in a pull operation.
///
/// Note: A pull is essentially the same as a fetch except we might
/// have to check out some files at the end. We assume that these
/// delta updates are fairly quick though.
private let steps = [
    ProgressStep(title: "remote: Compressing objects", weight: 0.1),
    ProgressStep(title: "Receiving objects", weight: 0.7),
    ProgressStep(title: "Resolving deltas", weight: 0.15),
    // Current git says "Updating files"; older git says "Checking out files".
    ProgressStep(title: "Checking out files", weight: 0.15, alternativeTitles: ["Updating files"]),
]

/// A utility for interpreting the output from `git pull --progress`
/// and turning that into a percentage value estimating the overall progress
/// of the pull.
public struct PullProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
