// Ported from desktop/app/src/lib/format-relative.ts
//
// `formatDate` always uses the user's date and time patterns (date-fns
// patterns, kept as the stored values). Number formats are GitKit's
// (`formatNumber`).

import Foundation
import GitKit
import Synchronization
import SwiftUI

/// A date format the user can choose (a date-fns pattern; the raw value is
/// what the `dateFormat` setting stores).
nonisolated public enum DateFormatPattern: String, CaseIterable, Sendable {
    case monthDayYear = "MMM d, yyyy"
    case longMonthOrdinalDayYear = "MMMM do, yyyy"
    case slashMonthDayYear = "MM/dd/yyyy"
    case slashDayMonthYear = "dd/MM/yyyy"
    case dashDayMonthYear = "dd-MM-yyyy"
    case dotDayMonthYear = "dd.MM.yyyy"
    case slashYearMonthDay = "yyyy/MM/dd"
    case dashYearMonthDay = "yyyy-MM-dd"
    case dotYearMonthDay = "yyyy.MM.dd"
    case slashMonthDayShortYear = "MM/dd/yy"
    case slashDayMonthShortYear = "dd/MM/yy"
    case dashDayMonthShortYear = "dd-MM-yy"
    case dotDayMonthShortYear = "dd.MM.yy"
    case slashShortYearMonthDay = "yy/MM/dd"
    case dashShortYearMonthDay = "yy-MM-dd"
    case dotShortYearMonthDay = "yy.MM.dd"

    /// The default date format.
    public static let `default`: DateFormatPattern = .monthDayYear

    /// The pattern formatted at the preview date (19 October 2017,
    /// 14:30:45), for the Settings pop-up.
    public var example: String {
        RelativeTime.format(RelativeTime.previewDate, pattern: rawValue, timeZone: .current)
    }
}

/// A time format the user can choose.
nonisolated public enum TimeFormatPattern: String, CaseIterable, Sendable {
    case colonHoursMinutesSeconds = "HH:mm:ss"
    case dotHoursMinutesSeconds = "HH.mm.ss"
    case colonHoursMinutes = "HH:mm"
    case dotHoursMinutes = "HH.mm"
    case colonTwelveHourSeconds = "h:mm:ss aaa"
    case dotTwelveHourSeconds = "h.mm.ss aaa"
    case colonTwelveHour = "h:mm aaa"
    case dotTwelveHour = "h.mm aaa"

    /// The default time format: 12-hour in the countries that use it (and
    /// when the country is unknown), 24-hour elsewhere.
    public static var `default`: TimeFormatPattern {
        let region = Locale.current.region?.identifier
        return region.map(twelveHourCountries.contains) ?? true ? .colonTwelveHour : .colonHoursMinutes
    }

    /// Countries that predominantly use 12-hour time.
    static let twelveHourCountries: Set<String> = ["GB", "IE", "US", "CA", "AU", "NZ", "ZA", "IN", "PK", "BD", "PH", "MX", "CO"]

    /// The pattern formatted at the preview date.
    public var example: String {
        RelativeTime.format(RelativeTime.previewDate, pattern: rawValue, timeZone: .current)
    }
}

/// How dates show: relative or absolute, and the user's patterns.
nonisolated public struct DateTimeFormatting: Sendable, Equatable {
    /// "Prefer absolute dates over relative" (`preferAbsoluteDates`).
    public var preferAbsoluteDates: Bool
    public var dateFormat: DateFormatPattern
    public var timeFormat: TimeFormatPattern

    public init(
        preferAbsoluteDates: Bool = false,
        dateFormat: DateFormatPattern = .default,
        timeFormat: TimeFormatPattern = .default
    ) {
        self.preferAbsoluteDates = preferAbsoluteDates
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
    }

    /// The formatting the settings describe; a stored pattern that isn't
    /// one of the choices reads as the default.
    public init(preferAbsoluteDates: Bool, dateFormat: String?, timeFormat: String?) {
        self.init(
            preferAbsoluteDates: preferAbsoluteDates,
            dateFormat: dateFormat.flatMap(DateFormatPattern.init(rawValue:)) ?? .default,
            timeFormat: timeFormat.flatMap(TimeFormatPattern.init(rawValue:)) ?? .default
        )
    }
}

/// Relative and absolute dates in words.
nonisolated public enum RelativeTime {
    /// The preview date for the format pop-ups: 19 October 2017, 14:30:45,
    /// local time.
    public static let previewDate: Date = {
        var components = DateComponents(year: 2017, month: 10, day: 19, hour: 14, minute: 30, second: 45)
        components.calendar = Calendar(identifier: .gregorian)
        return components.date ?? Date(timeIntervalSince1970: 1_508_423_445)
    }()

    /// A time interval in words: `interval` is the date minus now, in
    /// seconds; the unit is the largest that reads naturally ("5 minutes
    /// ago", "yesterday", "last month", "in 3 hours").
    public static func formatRelative(_ interval: TimeInterval) -> String {
        let sign = interval < 0 ? -1 : 1
        let seconds = Int((abs(interval)).rounded())
        let minutes = Int((Double(seconds) / 60).rounded())
        let hours = Int((Double(minutes) / 60).rounded())
        let days = Int((Double(hours) / 24).rounded())
        let months = Int((Double(days) / 30).rounded())
        let years = Int((Double(months) / 12).rounded())

        var components = DateComponents()
        if seconds < 45 {
            components.second = seconds * sign
        } else if minutes < 45 {
            components.minute = minutes * sign
        } else if hours < 24 {
            components.hour = hours * sign
        } else if days < 30 {
            components.day = days * sign
        } else if months < 18 {
            components.month = months * sign
        } else {
            components.year = years * sign
        }
        return formatters.withLock { cache in
            cache.relative.localizedString(from: components)
        }
    }

    /// A date as lists show it: relative ("2 hours ago", "just now"), or
    /// absolute with the user's patterns when they prefer absolute dates.
    /// A date more than a minute in the future is absolute.
    public static func describe(_ date: Date, now: Date, formatting: DateTimeFormatting = DateTimeFormatting(), timeZone: TimeZone = .current) -> String {
        if formatting.preferAbsoluteDates {
            return formatDate(date, formatting: formatting, timeZone: timeZone)
        }
        let difference = date.timeIntervalSince(now)
        let duration = abs(difference)
        if difference > 0, duration > 60 {
            return formatDate(date, formatting: formatting, timeZone: timeZone)
        }
        if duration < 60 {
            return "just now"
        }
        return formatRelative(difference)
    }

    /// The sync button's line: "Last fetched 5 minutes ago", or "Never
    /// fetched".
    public static func lastFetched(_ date: Date?, now: Date, formatting: DateTimeFormatting = DateTimeFormatting(), timeZone: TimeZone = .current) -> String {
        guard let date else {
            return "Never fetched"
        }
        return "Last fetched \(describe(date, now: now, formatting: formatting, timeZone: timeZone))"
    }

    /// A date with the user's date and time patterns. Pass `date: false` or
    /// `time: false` for one part.
    public static func formatDate(
        _ value: Date,
        formatting: DateTimeFormatting = DateTimeFormatting(),
        date: Bool = true,
        time: Bool = true,
        timeZone: TimeZone = .current
    ) -> String {
        switch (date, time) {
        case (true, true):
            "\(format(value, pattern: formatting.dateFormat.rawValue, timeZone: timeZone)) \(format(value, pattern: formatting.timeFormat.rawValue, timeZone: timeZone))"
        case (true, false):
            format(value, pattern: formatting.dateFormat.rawValue, timeZone: timeZone)
        case (false, true):
            format(value, pattern: formatting.timeFormat.rawValue, timeZone: timeZone)
        case (false, false):
            ""
        }
    }

    /// Formats a date with one of the date-fns patterns. Unicode patterns
    /// match date-fns' except `do` (an ordinal day, "19th") and `aaa` (a
    /// lowercase "am" or "pm"), which are spelled out as literals.
    static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.day, .hour], from: date)
        var unicodePattern = pattern
        if unicodePattern.contains("do"), let day = components.day {
            unicodePattern = unicodePattern.replacingOccurrences(of: "do", with: "'\(ordinal(day))'")
        }
        if unicodePattern.contains("aaa"), let hour = components.hour {
            unicodePattern = unicodePattern.replacingOccurrences(of: "aaa", with: hour < 12 ? "'am'" : "'pm'")
        }
        // Making a date formatter costs far more than using one (lists
        // format a date per row), so they're kept per pattern and time zone.
        let pattern = unicodePattern
        return formatters.withLock { cache in
            let key = "\(pattern)|\(timeZone.identifier)"
            if let formatter = cache.dates[key] {
                return formatter.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            if cache.dates.count >= 256 {
                cache.dates.removeAll()
            }
            cache.dates[key] = formatter
            return formatter.string(from: date)
        }
    }

    /// An English ordinal ("1st", "22nd", "13th"), as date-fns' `do`.
    static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 100, number % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }

    /// The formatters, made once each and used one caller at a time.
    private static let formatters = Mutex(FormatterCache())
}

/// `RelativeTime`'s formatters.
nonisolated private struct FormatterCache {
    /// `Intl.RelativeTimeFormat('en-US', { numeric: 'auto' })`.
    let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Date formatters by pattern and time zone.
    var dates: [String: DateFormatter] = [:]
}

extension EnvironmentValues {
    /// How dates show; the app sets it from the settings.
    @Entry public var dateTimeFormatting = DateTimeFormatting()
}

/// A date in words, refreshed once a minute, with the absolute date and time
/// in the tooltip.
public struct RelativeTimeText: View {
    private let date: Date
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    public init(_ date: Date) {
        self.date = date
    }

    public var body: some View {
        TimelineView(.everyMinute) { context in
            text(now: context.date)
        }
    }

    private func text(now: Date) -> some View {
        Text(RelativeTime.describe(date, now: now, formatting: formatting, timeZone: timeZone))
            .tooltip(RelativeTime.formatDate(date, formatting: formatting, timeZone: timeZone))
    }
}
