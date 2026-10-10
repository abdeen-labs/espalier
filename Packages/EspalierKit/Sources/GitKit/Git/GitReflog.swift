// Ported from desktop/app/src/lib/git/reflog.ts

import EspalierSupport
import Foundation

/// A pattern matching `word` case-insensitively the way JavaScript's
/// non-Unicode `i` flag does for ASCII letters: each letter matches only its
/// two ASCII cases. (ICU's case-insensitive mode would also match, for
/// example, U+017F (long s) for `s` and U+212A (Kelvin sign) for `k`;
/// JavaScript doesn't.)
private func asciiCaseInsensitive(_ word: String) -> String {
    word.unicodeScalars.map { scalar -> String in
        let character = Character(scalar)
        if scalar.isASCII, character.isLetter {
            return "[\(character.lowercased())\(character.uppercased())]"
        }
        return NSRegularExpression.escapedPattern(for: String(character))
    }.joined()
}

/// `/.*? (renamed|checkout)(?:: moving from|\s*) (?:refs\/heads\/|\s*)(.*?) to (?:refs\/heads\/|\s*)(.*?)$/i`
private let recentBranchesPattern: NSRegularExpression = {
    let dot = JSCompat.dot
    let space = JSCompat.whitespace
    let renamed = asciiCaseInsensitive("renamed")
    let checkout = asciiCaseInsensitive("checkout")
    let movingFrom = asciiCaseInsensitive(": moving from")
    let refsHeads = asciiCaseInsensitive("refs/heads/")
    let to = asciiCaseInsensitive(" to ")
    return JSCompat.regex(
        "\(dot)*? (\(renamed)|\(checkout))(?:\(movingFrom)|\(space)*) (?:\(refsHeads)|\(space)*)(\(dot)*?)\(to)(?:\(refsHeads)|\(space)*)(\(dot)*?)\\z"
    )
}()

/// Get the `limit` most recently checked out branches.
public func getRecentBranches(_ repository: Repository, _ limit: Int) async throws -> [String] {
    // "git reflog show" is just an alias for "git log -g --abbrev-commit --pretty=oneline"
    // but by using log we can give it a max number which should prevent us from balling out
    // of control when there's ginormous reflogs around (as in e.g. github/github).
    let result = try await git(
        [
            "log",
            "-g",
            "--no-abbrev-commit",
            "--pretty=oneline",
            "HEAD",
            "-n",
            "2500",
            "--",
        ],
        repository.path,
        "getRecentBranches",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )

    if result.exitCode == 128 {
        // error code 128 is returned if the branch is unborn
        return []
    }

    let lines = JSCompat.split(result.stdout, "\n")
    // In insertion order, without duplicates.
    var names: [String] = []
    var seenNames = Set<String>()
    var excludedNames = Set<String>()

    for line in lines {
        if let result = JSCompat.match(line, recentBranchesPattern), result.count == 4 {
            let operationType = result[1] ?? ""
            let excludeBranchName = result[2] ?? ""
            let branchName = result[3] ?? ""

            if operationType == "renamed" {
                // exclude intermediate-state renaming branch from recent branches
                excludedNames.insert(excludeBranchName)
            }

            if !excludedNames.contains(branchName), !seenNames.contains(branchName) {
                seenNames.insert(branchName)
                names.append(branchName)
            }
        }

        if names.count == limit {
            break
        }
    }

    return names
}

/// `/fatal: your current branch '.*' does not have any commits yet/`
private let noCommitsOnBranchRe = JSCompat.regex(
    "fatal: your current branch '\(JSCompat.dot)*' does not have any commits yet"
)

/// `/^[a-z0-9]{40}\sHEAD@{(.*)}\scheckout: moving from\s.*\sto\s(.*)$/`
///
/// Also accepts 64-character object IDs, for SHA-256 repositories.
private let branchCheckoutPattern: NSRegularExpression = {
    let dot = JSCompat.dot
    let space = JSCompat.whitespace
    return JSCompat.regex(
        "^(?:[a-z0-9]{40}|[a-z0-9]{64})\(space)HEAD@\\{(\(dot)*)\\}\(space)checkout: moving from\(space)\(dot)*\(space)to\(space)(\(dot)*)\\z"
    )
}()

/// Gets the distinct list of branches that have been checked out after a specific date
/// Returns a map keyed on branch names
///
/// - Parameters:
///   - repository: the repository who's reflog you want to check
///   - afterDate: filters checkouts so that only those occurring on or after this date are returned
/// - Returns: map of branch name -> checkout date
public func getBranchCheckouts(_ repository: Repository, _ afterDate: Date) async throws -> [String: Date] {
    var options = GitExecutionOptions(successExitCodes: [0, 128])
    // The pattern's `.` matches a branch name that isn't UTF-8 only without
    // a UTF-8 locale.
    options.addsDefaultLocale = false
    //regexr.com/46n1v
    let result = try await git(
        [
            "reflog",
            "--date=iso",
            "--after=\"\(javaScriptISOString(afterDate))\"",
            "--pretty=%H %gd %gs",
            "--grep-reflog=checkout: moving from .* to .*$",
            "--",
        ],
        repository.path,
        "getCheckoutsAfterDate",
        options: options
    )

    var checkouts: [String: Date] = [:]

    // edge case where orphaned branch is created but Git raises error when
    // reading the reflog on this new branch as it has no commits
    if result.exitCode == 128, JSCompat.match(result.stderr, noCommitsOnBranchRe) != nil {
        return checkouts
    }

    let lines = JSCompat.split(result.stdout, "\n")
    for line in lines {
        guard let parsedLine = JSCompat.match(line, branchCheckoutPattern), parsedLine.count == 3,
              let timestamp = parsedLine[1], let branchName = parsedLine[2]
        else {
            continue
        }

        if checkouts[branchName] == nil {
            checkouts[branchName] = parseGitISODate(timestamp)
        }
    }

    return checkouts
}

/// JavaScript's `date.toISOString()`: `YYYY-MM-DDTHH:mm:ss.sssZ` in UTC.
///
/// A JavaScript date holds whole milliseconds (its constructor truncates
/// toward zero). A `Date` holds seconds since 2001 as a double, so a whole
/// number of milliseconds can come back as, say, 37.0039999 seconds; a value
/// within that rounding error of a whole millisecond is taken as that
/// millisecond.
func javaScriptISOString(_ date: Date) -> String {
    let scaled = date.timeIntervalSince1970 * 1000
    let nearest = scaled.rounded()
    let noise = max(date.timeIntervalSinceReferenceDate.ulp, date.timeIntervalSince1970.ulp) * 1000 * 4
    let milliseconds = Int64(abs(scaled - nearest) <= noise ? nearest : scaled.rounded(.towardZero))
    var seconds = time_t(milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000)
    let fraction = milliseconds - Int64(seconds) * 1000
    var components = tm()
    gmtime_r(&seconds, &components)
    let year = Int(components.tm_year) + 1900
    let yearText = (0...9999).contains(year)
        ? String(format: "%04ld", year)
        : String(format: "%@%06ld", year < 0 ? "-" : "+", abs(year))
    return String(
        format: "%@-%02d-%02dT%02d:%02d:%02d.%03dZ",
        yearText,
        components.tm_mon + 1,
        components.tm_mday,
        components.tm_hour,
        components.tm_min,
        components.tm_sec,
        Int32(fraction)
    )
}

/// `YYYY-MM-DD HH:MM:SS +ZZZZ`, git's `--date=iso`.
private let gitISODatePattern = JSCompat.regex(
    "^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\\z"
)

/// JavaScript's `new Date(timestamp)` for git's `--date=iso` format.
/// Anything else is an invalid date (NaN), as it would be in JavaScript.
func parseGitISODate(_ timestamp: String) -> Date {
    guard let match = JSCompat.match(timestamp, gitISODatePattern) else {
        return Date(timeIntervalSince1970: .nan)
    }
    let numbers = match.dropFirst().map { $0.flatMap { Int($0) } }
    guard let year = numbers[0], let month = numbers[1], let day = numbers[2],
          let hour = numbers[3], let minute = numbers[4], let second = numbers[5],
          let offsetHours = numbers[7], let offsetMinutes = numbers[8]
    else {
        return Date(timeIntervalSince1970: .nan)
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let utc = calendar.date(from: components) else {
        return Date(timeIntervalSince1970: .nan)
    }
    let offset = (offsetHours * 3600 + offsetMinutes * 60) * (match[7] == "-" ? -1 : 1)
    return utc.addingTimeInterval(TimeInterval(-offset))
}
