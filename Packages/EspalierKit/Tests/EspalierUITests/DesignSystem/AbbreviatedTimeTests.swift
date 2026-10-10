// Dates short enough for the simple list's time column
// (`RelativeTime.abbreviated`).

import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Abbreviated time")
struct AbbreviatedTimeTests {
    /// 2026-10-06 10:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_280_800)
    private static let utc = TimeZone(identifier: "UTC")!

    private static let cases: [NamedCase<(TimeInterval, String)>] = [
        NamedCase("just now", (-30.0, "now")),
        NamedCase("minutes", (-12 * 60.0, "12m")),
        NamedCase("an hour, rounded down", (-119 * 60.0, "1h")),
        NamedCase("a day ago", (-25 * 3_600.0, "Oct 5")),
        NamedCase("earlier this year", (-250 * 86_400.0, "Jan 29")),
        NamedCase("last year, longer ago", (-400 * 86_400.0, "2025")),
        NamedCase("in a minute's leeway", (50.0, "now")),
        NamedCase("in the future", (2 * 86_400.0, "Oct 8")),
    ]

    @Test("relative under a day, then the day this year or in the last six months, else the year", arguments: cases)
    func abbreviated(_ testCase: NamedCase<(TimeInterval, String)>) {
        let (offset, expected) = testCase.value
        let date = Self.now.addingTimeInterval(offset)
        #expect(RelativeTime.abbreviated(date, now: Self.now, timeZone: Self.utc) == expected)
    }

    @Test("absolute dates preferred: always the day; a day-first format puts the day first")
    func formatting() {
        let twelveMinutesAgo = Self.now.addingTimeInterval(-12 * 60)
        #expect(RelativeTime.abbreviated(twelveMinutesAgo, now: Self.now, formatting: DateTimeFormatting(preferAbsoluteDates: true), timeZone: Self.utc) == "Oct 6")
        let dayFirst = DateTimeFormatting(dateFormat: .dotDayMonthYear)
        #expect(RelativeTime.abbreviated(Self.now.addingTimeInterval(-25 * 3_600), now: Self.now, formatting: dayFirst, timeZone: Self.utc) == "5 Oct")
        #expect(RelativeTime.abbreviated(twelveMinutesAgo, now: Self.now, formatting: dayFirst, timeZone: Self.utc) == "12m")
    }

    @Test("last year's days within six months keep their day")
    func newYear() {
        // 2026-01-02 10:00 UTC.
        let newYear = Date(timeIntervalSince1970: 1_767_348_000)
        #expect(RelativeTime.abbreviated(newYear.addingTimeInterval(-3 * 86_400), now: newYear, timeZone: Self.utc) == "Dec 30")
        #expect(RelativeTime.abbreviated(newYear.addingTimeInterval(-200 * 86_400), now: newYear, timeZone: Self.utc) == "2025")
    }
}
