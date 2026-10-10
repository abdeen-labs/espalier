// Ported from desktop/app/src/lib/progress/git.ts

import EspalierSupport
import Foundation

/// Identifies a particular subset of progress events from Git by
/// title.
public struct ProgressStep: Hashable, Sendable {
    /// The title of the git progress event. By title we refer to the
    /// exact value of the title field in the Git progress struct:
    ///
    /// https://github.com/git/git/blob/6a2c2f8d34fa1e8f3bb85d159d354810ed63692e/progress.c#L31-L39
    ///
    /// In essence this means anything up to (but not including) the last colon (:)
    /// in a single progress line. Take this example progress line
    ///
    ///    remote: Compressing objects:  14% (159/1133)
    ///
    /// In this case the title would be 'remote: Compressing objects'.
    public let title: String

    /// The weight of this step in relation to others for a particular
    /// Git operation. This value can be any number as long as it's
    /// proportional to others in the same parser, it will all be scaled
    /// to a decimal value between 0 and 1 before being used to calculate
    /// overall progress.
    public let weight: Double

    /// Other titles git uses for the same step (git says "Updating files"
    /// where it once said "Checking out files").
    public let alternativeTitles: [String]

    public init(title: String, weight: Double, alternativeTitles: [String] = []) {
        self.title = title
        self.weight = weight
        self.alternativeTitles = alternativeTitles
    }

    func matches(_ title: String) -> Bool {
        JSCompat.strictEquals(title, self.title)
            || alternativeTitles.contains { JSCompat.strictEquals(title, $0) }
    }
}

/// The overall progress of one or more steps in a Git operation.
public struct GitProgress: Hashable, Sendable {
    /// The overall percent of the operation
    public let percent: Double

    /// The underlying progress line that this progress instance was
    /// constructed from. Note that the percent value in details
    /// doesn't correspond to that of percent in this instance for
    /// two reasons. Fist, we calculate percent by dividing value with total
    /// to produce a high precision decimal value between 0 and 1 while
    /// details.percent is a rounded integer between 0 and 100.
    ///
    /// Second, the percent in this instance is scaled in relation to any
    /// other steps included in the progress parser.
    public let details: GitProgressInfo

    public init(percent: Double, details: GitProgressInfo) {
        self.percent = percent
        self.details = details
    }
}

/// A line of git's output that isn't progress of a known step.
public struct GitOutput: Hashable, Sendable {
    public let percent: Double
    public let text: String

    public init(percent: Double, text: String) {
        self.percent = percent
        self.text = text
    }
}

/// The result of parsing a line: progress or other output. The cases are
/// their `kind` values.
public enum GitProgressResult: Hashable, Sendable {
    case progress(GitProgress)
    case context(GitOutput)

    /// The overall percent of the operation.
    public var percent: Double {
        switch self {
        case .progress(let progress): progress.percent
        case .context(let output): output.percent
        }
    }

    /// The text to show the user: the progress line or the output line.
    public var text: String {
        switch self {
        case .progress(let progress): progress.details.text
        case .context(let output): output.text
        }
    }
}

/// A well-structured representation of a Git progress line.
public struct GitProgressInfo: Hashable, Sendable {
    /// The title of the git progress event. By title we refer to the
    /// exact value of the title field in Git's progress struct:
    ///
    /// https://github.com/git/git/blob/6a2c2f8d34fa1e8f3bb85d159d354810ed63692e/progress.c#L31-L39
    ///
    /// In essence this means anything up to (but not including) the last colon (:)
    /// in a single progress line. Take this example progress line
    ///
    ///    remote: Compressing objects:  14% (159/1133)
    ///
    /// In this case the title would be 'remote: Compressing objects'.
    public let title: String

    /// The progress value as parsed from the Git progress line.
    ///
    /// We define value to mean the same as it does in the Git progress struct, i.e
    /// it's the number of processed units.
    ///
    /// In the progress line 'remote: Compressing objects:  14% (159/1133)' the
    /// value is 159.
    ///
    /// In the progress line 'remote: Counting objects: 123' the value is 123.
    public let value: Int

    /// The progress total as parsed from the git progress line.
    ///
    /// We define total to mean the same as it does in the Git progress struct, i.e
    /// it's the total number of units in a given process.
    ///
    /// In the progress line 'remote: Compressing objects:  14% (159/1133)' the
    /// total is 1133.
    ///
    /// In the progress line 'remote: Counting objects: 123' the total is undefined.
    public let total: Int?

    /// The progress percent as parsed from the git progress line represented as
    /// an integer between 0 and 100.
    ///
    /// We define percent to mean the same as it does in the Git progress struct, i.e
    /// it's the value divided by total.
    ///
    /// In the progress line 'remote: Compressing objects:  14% (159/1133)' the
    /// percent is 14.
    ///
    /// In the progress line 'remote: Counting objects: 123' the percent is undefined.
    public let percent: Int?

    /// Whether or not the parsed git progress line indicates that the operation
    /// is done.
    ///
    /// This is denoted by a trailing ", done" string in the progress line.
    /// Example: Checking out files:  100% (728/728), done
    public let done: Bool

    /// The untouched raw text line that this instance was parsed from. Useful
    /// for presenting the actual output from Git to the user.
    public let text: String

    public init(title: String, value: Int, total: Int?, percent: Int?, done: Bool, text: String) {
        self.title = title
        self.value = value
        self.total = total
        self.percent = percent
        self.done = done
        self.text = text
    }

    /// Attempts to parse a single line of progress output from Git.
    ///
    /// For details about how Git formats progress see
    ///
    ///   https://github.com/git/git/blob/6a2c2f8d34fa1e8f3bb85d159d354810ed63692e/progress.c
    ///
    /// Some examples:
    ///  remote: Counting objects: 123
    ///  remote: Counting objects: 167587, done.
    ///  Receiving objects:  99% (166741/167587), 272.10 MiB | 2.39 MiB/s
    ///  Checking out files:  100% (728/728)
    ///  Checking out files:  100% (728/728), done
    ///
    /// - Returns: An object containing well-structured information about the
    ///   progress or nil if the line could not be parsed as a Git progress
    ///   line.
    public static func parse(_ line: String) -> GitProgressInfo? {
        let scalars = line.unicodeScalars

        // The title ends at the last ': '. A line without one has no title,
        // so it isn't progress.
        guard let separator = lastIndex(of: ": ", in: scalars), separator != scalars.startIndex else {
            return nil
        }

        let title = String(scalars[..<separator])
        let progressText = JSCompat.trim(String(scalars[scalars.index(separator, offsetBy: 2)...]))

        if progressText.isEmpty {
            return nil
        }

        let progressParts = JSCompat.split(progressText, ", ")

        let value: Int
        var total: Int?
        var percent: Int?

        if isValueOnly(progressParts[0]) {
            guard let parsed = JSCompat.parseInt(progressParts[0]) else {
                return nil
            }
            value = parsed
        } else {
            guard let match = matchPercent(progressParts[0]) else {
                return nil
            }

            percent = match.percent
            value = match.value
            total = match.total
        }

        var done = false

        // We don't parse throughput at the moment so let's just loop
        // through the remaining
        for part in progressParts.dropFirst() where JSCompat.strictEquals(part, "done.") {
            done = true
            break
        }

        return GitProgressInfo(title: title, value: value, total: total, percent: percent, done: done, text: line)
    }

    /// `/^\d+$/`
    private static func isValueOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isDigit)
    }

    /// `/^(\d{1,3})% \((\d+)\/(\d+)\)$/`
    private static func matchPercent(_ text: String) -> (percent: Int, value: Int, total: Int)? {
        var scalars = Substring(text).unicodeScalars[...]

        func digits(maxCount: Int = .max) -> Int? {
            let run = scalars.prefix { isDigit($0) }.prefix(maxCount)
            guard !run.isEmpty, let number = JSCompat.parseInt(String(run)) else {
                return nil
            }
            scalars = scalars.dropFirst(run.count)
            return number
        }

        func literal(_ expected: String) -> Bool {
            guard scalars.starts(with: expected.unicodeScalars) else {
                return false
            }
            scalars = scalars.dropFirst(expected.unicodeScalars.count)
            return true
        }

        guard let percent = digits(maxCount: 3),
              literal("% ("),
              let value = digits(),
              literal("/"),
              let total = digits(),
              literal(")"),
              scalars.isEmpty
        else {
            return nil
        }
        return (percent, value, total)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func lastIndex(
        of needle: String,
        in scalars: String.UnicodeScalarView
    ) -> String.UnicodeScalarView.Index? {
        let needle = Array(needle.unicodeScalars)
        var index = scalars.endIndex
        while index != scalars.startIndex {
            index = scalars.index(before: index)
            if scalars[index...].starts(with: needle) {
                return index
            }
        }
        return nil
    }
}

/// Interface for classes interpreting progress output from `git`
/// and turning that into a percentage value estimating the overall progress
/// of the an operation. An operation could be something like `git fetch`
/// which contains multiple steps, each individually reported by Git as
/// progress events between 0 and 100%.
public protocol GitProgressParsing: Sendable {
    /// Parse the given line of output from Git, returns either a `.progress`
    /// result if the line could successfully be parsed as a Git progress
    /// event whose title was registered with this parser or a `.context`
    /// result if the line couldn't be parsed or if the title wasn't
    /// registered with the parser.
    mutating func parse(_ line: String) -> GitProgressResult
}

/// The error `GitProgressParser.init` throws for an empty list of steps.
public struct GitProgressParserError: Error, Equatable, CustomStringConvertible {
    public var description: String { "must specify at least one step" }
}

/// A utility for interpreting progress output from `git`
/// and turning that into a percentage value estimating the overall progress
/// of the an operation. An operation could be something like `git fetch`
/// which contains multiple steps, each individually reported by Git as
/// progress events between 0 and 100%.
///
/// A parser cannot be reused, it's mean to parse a single stderr stream
/// for Git.
public struct GitProgressParser: GitProgressParsing {
    private let steps: [ProgressStep]

    /// The provided steps should always occur in order but some
    /// might not happen at all (like remote compression of objects) so
    /// we keep track of the "highest" seen step so that we can fill in
    /// progress with the assumption that we've already seen the previous
    /// steps.
    private var stepIndex = 0

    private var lastPercent: Double = 0

    /// Initialize a new instance of a Git progress parser.
    ///
    /// - Parameter steps: A series of steps that could be present in the git
    ///   output with relative weight between these steps. Note
    ///   that order is significant here as once the parser sees
    ///   a progress line that matches a step all previous steps
    ///   are considered completed and overall progress is adjusted
    ///   accordingly.
    public init(_ steps: [ProgressStep]) throws(GitProgressParserError) {
        if steps.isEmpty {
            throw GitProgressParserError()
        }

        // Scale the step weight so that they're all a percentage
        // adjusted to the total weight of all steps.
        let totalStepWeight = steps.reduce(0) { $0 + $1.weight }

        self.steps = steps.map { step in
            ProgressStep(
                title: step.title,
                // The revert parser's only step weighs nothing; dividing by
                // zero would give NaN.
                weight: totalStepWeight == 0 ? 0 : step.weight / totalStepWeight,
                alternativeTitles: step.alternativeTitles
            )
        }
    }

    /// Parse the given line of output from Git, returns either a `.progress`
    /// result if the line could successfully be parsed as a Git progress
    /// event whose title was registered with this parser or a `.context`
    /// result if the line couldn't be parsed or if the title wasn't
    /// registered with the parser.
    public mutating func parse(_ line: String) -> GitProgressResult {
        // In case we're parsing hook output or similar we want to
        // strip out any control characters that may be present. A progress
        // result is supposed to be readable text that can be used in tooltips
        // and such.
        let text = stripVTControlCharacters(line)

        guard let progress = GitProgressInfo.parse(text) else {
            return .context(GitOutput(percent: lastPercent, text: text))
        }

        var percent: Double = 0

        for (i, step) in steps.enumerated() {
            if i >= stepIndex && step.matches(progress.title) {
                if let total = progress.total, total != 0 {
                    percent += step.weight * (Double(progress.value) / Double(total))
                }

                stepIndex = i
                lastPercent = percent

                return .progress(GitProgress(percent: percent, details: progress))
            } else {
                percent += step.weight
            }
        }

        return .context(GitOutput(percent: lastPercent, text: text))
    }
}

/// The ANSI escape sequences `stripVTControlCharacters` removes.
private let ansiPattern = JSCompat.regex(
    #"[\u001B\u009B][\[\]()#;?]*"#
        + #"(?:(?:(?:(?:;[-a-zA-Z0-9/#&.:=?%@~_]+)*"#
        + #"|[a-zA-Z0-9]+(?:;[-a-zA-Z0-9/#&.:=?%@~_]*)*)?"#
        // The backslash in ESC \ is written \\: ICU expands \u escapes before
        // parsing, so the escape for U+005C would escape the next character.
        + #"(?:\u0007|\u001B\\|\u009C))"#
        + #"|(?:(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?"#
        + #"[0-9A-PR-TZcf-nq-uy=><~]))"#
)

/// Removes ANSI escape codes from `text`.
func stripVTControlCharacters(_ text: String) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}
