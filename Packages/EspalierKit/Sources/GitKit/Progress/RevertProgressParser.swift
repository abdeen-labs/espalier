// Ported from desktop/app/src/lib/progress/revert.ts

private let steps = [ProgressStep(title: "", weight: 0)]

/// Parses output from `git revert` and provides structured progress events.
///
/// `git revert` reports no progress of its own, so every line is context;
/// the progress worth showing comes from Git LFS.
public struct RevertProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
