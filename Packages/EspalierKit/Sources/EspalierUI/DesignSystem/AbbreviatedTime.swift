// A date short enough for a narrow column (the time in SF Mono 11 in a
// 44-wide column, "12m", "1h", "18h", "Oct 5").

import Foundation

extension RelativeTime {
    /// `date` in at most six characters: "now", minutes ("12m") and hours
    /// ("18h") under a day ago, then the day ("Oct 5", or "5 Oct" when the
    /// user's date format puts the day first) this year or in the last six
    /// months, else the year ("2024"). With absolute dates preferred, and
    /// for dates in the future, the day or the year.
    nonisolated public static func abbreviated(
        _ date: Date,
        now: Date,
        formatting: DateTimeFormatting = DateTimeFormatting(),
        timeZone: TimeZone = .current
    ) -> String {
        let elapsed = now.timeIntervalSince(date)
        if !formatting.preferAbsoluteDates, elapsed > -60 {
            if elapsed < 60 {
                return "now"
            }
            if elapsed < 3_600 {
                return "\(Int(elapsed / 60))m"
            }
            if elapsed < 86_400 {
                return "\(Int(elapsed / 3_600))h"
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let isRecent = elapsed < 183 * 86_400
        guard isThisYear || isRecent else {
            return format(date, pattern: "yyyy", timeZone: timeZone)
        }
        let dayFirst = formatting.dateFormat.rawValue.hasPrefix("dd")
        return format(date, pattern: dayFirst ? "d MMM" : "MMM d", timeZone: timeZone)
    }
}
