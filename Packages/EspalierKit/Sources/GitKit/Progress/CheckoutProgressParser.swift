// Ported from desktop/app/src/lib/progress/checkout.ts

// Current git says "Updating files"; older git says "Checking out files".
private let steps = [
    ProgressStep(title: "Checking out files", weight: 1, alternativeTitles: ["Updating files"]),
]

/// Parses output from `git checkout --progress` and provides structured
/// progress events.
public struct CheckoutProgressParser: GitProgressParsing {
    private var parser = try! GitProgressParser(steps)

    public init() {}

    public mutating func parse(_ line: String) -> GitProgressResult {
        parser.parse(line)
    }
}
