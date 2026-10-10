// Ported in part from desktop/app/test/unit/format-relative-test.ts
//
// Relative and absolute dates, and the date and time patterns (date-fns
// patterns, with "do" and "aaa" spelled out).

import Foundation
import Testing
@testable import EspalierUI

@Suite("Relative time")
struct RelativeTimeTests {
    private let second: TimeInterval = 1
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    @Test("formatRelative picks desktop's unit")
    func formatRelative() {
        #expect(RelativeTime.formatRelative(0) == "now")
        #expect(RelativeTime.formatRelative(-10 * second) == "10 seconds ago")
        #expect(RelativeTime.formatRelative(-44 * second) == "44 seconds ago")
        #expect(RelativeTime.formatRelative(-45 * second) == "1 minute ago")
        #expect(RelativeTime.formatRelative(-5 * minute) == "5 minutes ago")
        #expect(RelativeTime.formatRelative(-45 * minute) == "1 hour ago")
        #expect(RelativeTime.formatRelative(-3 * hour) == "3 hours ago")
        #expect(RelativeTime.formatRelative(-24 * hour) == "yesterday")
        #expect(RelativeTime.formatRelative(-3 * day) == "3 days ago")
        #expect(RelativeTime.formatRelative(-30 * day) == "last month")
        #expect(RelativeTime.formatRelative(-90 * day) == "3 months ago")
        #expect(RelativeTime.formatRelative(-400 * day) == "13 months ago")
        // The rounding goes from 17 months to 2 years.
        #expect(RelativeTime.formatRelative(-540 * day) == "2 years ago")
        #expect(RelativeTime.formatRelative(-1_200 * day) == "3 years ago")
        #expect(RelativeTime.formatRelative(3 * hour) == "in 3 hours")
        #expect(RelativeTime.formatRelative(24 * hour) == "tomorrow")
    }

    @Test("describe says just now, relative, or absolute, as desktop's RelativeTime")
    func describe() {
        let now = UIFixtures.now
        let utc = UIFixtures.timeZone
        let formatting = DateTimeFormatting(dateFormat: .monthDayYear, timeFormat: .colonTwelveHour)
        #expect(RelativeTime.describe(now.addingTimeInterval(-30), now: now, formatting: formatting, timeZone: utc) == "just now")
        #expect(RelativeTime.describe(now.addingTimeInterval(30), now: now, formatting: formatting, timeZone: utc) == "just now")
        #expect(RelativeTime.describe(now.addingTimeInterval(-2 * hour), now: now, formatting: formatting, timeZone: utc) == "2 hours ago")
        #expect(RelativeTime.describe(now.addingTimeInterval(-10 * day), now: now, formatting: formatting, timeZone: utc) == "10 days ago")
        // The future, and a preference for absolute dates, show the date.
        #expect(RelativeTime.describe(now.addingTimeInterval(2 * hour), now: now, formatting: formatting, timeZone: utc) == "Oct 6, 2026 12:00 pm")
        var absolute = formatting
        absolute.preferAbsoluteDates = true
        #expect(RelativeTime.describe(now.addingTimeInterval(-2 * hour), now: now, formatting: absolute, timeZone: utc) == "Oct 6, 2026 8:00 am")
        #expect(RelativeTime.lastFetched(nil, now: now) == "Never fetched")
        #expect(RelativeTime.lastFetched(now.addingTimeInterval(-5 * minute), now: now, timeZone: utc) == "Last fetched 5 minutes ago")
    }

    @Test("the date and time patterns format as date-fns does")
    func patterns() {
        // The preview date: 19 October 2017, 14:30:45.
        let utc = UIFixtures.timeZone
        var components = DateComponents(year: 2017, month: 10, day: 19, hour: 14, minute: 30, second: 45)
        components.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let expectedDates: [DateFormatPattern: String] = [
            .monthDayYear: "Oct 19, 2017",
            .longMonthOrdinalDayYear: "October 19th, 2017",
            .slashMonthDayYear: "10/19/2017",
            .dotDayMonthYear: "19.10.2017",
            .dashYearMonthDay: "2017-10-19",
            .slashShortYearMonthDay: "17/10/19",
        ]
        for (pattern, expected) in expectedDates {
            #expect(RelativeTime.format(date, pattern: pattern.rawValue, timeZone: utc) == expected)
        }
        let expectedTimes: [TimeFormatPattern: String] = [
            .colonHoursMinutesSeconds: "14:30:45",
            .dotHoursMinutes: "14.30",
            .colonTwelveHour: "2:30 pm",
            .dotTwelveHourSeconds: "2.30.45 pm",
        ]
        for (pattern, expected) in expectedTimes {
            #expect(RelativeTime.format(date, pattern: pattern.rawValue, timeZone: utc) == expected)
        }
        #expect(RelativeTime.ordinal(1) == "1st")
        #expect(RelativeTime.ordinal(2) == "2nd")
        #expect(RelativeTime.ordinal(3) == "3rd")
        #expect(RelativeTime.ordinal(11) == "11th")
        #expect(RelativeTime.ordinal(12) == "12th")
        #expect(RelativeTime.ordinal(13) == "13th")
        #expect(RelativeTime.ordinal(22) == "22nd")
        #expect(RelativeTime.ordinal(31) == "31st")
        #expect(DateFormatPattern.allCases.count == 16 && TimeFormatPattern.allCases.count == 8)
    }

    @Test("stored patterns that aren't desktop's read as the defaults")
    func storedPatterns() {
        let formatting = DateTimeFormatting(preferAbsoluteDates: true, dateFormat: "yyyy", timeFormat: nil)
        #expect(formatting.dateFormat == .monthDayYear)
        #expect(formatting.timeFormat == TimeFormatPattern.default)
        #expect(DateTimeFormatting(preferAbsoluteDates: false, dateFormat: "dd.MM.yy", timeFormat: "HH:mm").dateFormat == .dotDayMonthShortYear)
    }
}
