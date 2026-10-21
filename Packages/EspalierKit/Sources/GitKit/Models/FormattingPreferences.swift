// Ported from desktop/app/src/models/formatting-preferences.ts
//
// Only the number format, which `formatNumber` reads (Git LFS progress shows
// formatted byte counts).

import Foundation

/// Configuration for number formatting with separate thousands and decimal
/// separator characters.
public struct NumberFormat: Hashable, Sendable {
    public enum ThousandsSeparator: String, Hashable, Sendable {
        case comma = ","
        case period = "."
        case space = " "
        case none = ""
    }

    public enum DecimalSeparator: String, Hashable, Sendable {
        case comma = ","
        case period = "."
    }

    public let thousandsSeparator: ThousandsSeparator
    public let decimalSeparator: DecimalSeparator
    public let maximumFractionDigits: Int?

    public init(
        thousandsSeparator: ThousandsSeparator,
        decimalSeparator: DecimalSeparator,
        maximumFractionDigits: Int? = nil
    ) {
        self.thousandsSeparator = thousandsSeparator
        self.decimalSeparator = decimalSeparator
        self.maximumFractionDigits = maximumFractionDigits
    }
}

/// All valid number format configurations.
///
/// Excludes configurations where the thousands and decimal separator are the
/// same character.
public let numberFormats: [NumberFormat] = [
    NumberFormat(thousandsSeparator: .none, decimalSeparator: .period),
    NumberFormat(thousandsSeparator: .none, decimalSeparator: .comma),
    NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period),
    NumberFormat(thousandsSeparator: .period, decimalSeparator: .comma),
    NumberFormat(thousandsSeparator: .space, decimalSeparator: .period),
    NumberFormat(thousandsSeparator: .space, decimalSeparator: .comma),
]

/// The format of the six nearest to `locale`'s separators. The decimal
/// separator is a comma, or else a period (the Arabic decimal separator,
/// U+066B, included). The grouping separator is a comma (the Arabic
/// thousands separator, U+066C, included), a period, none when the locale
/// has none, or else a space, for the spaces and apostrophes that group
/// digits in France, Switzerland, and elsewhere; one that would match the
/// decimal separator is a space.
public func nearestNumberFormat(to locale: Locale) -> NumberFormat {
    let decimal: NumberFormat.DecimalSeparator = locale.decimalSeparator == "," ? .comma : .period
    var thousands: NumberFormat.ThousandsSeparator
    switch locale.groupingSeparator ?? "" {
    case "":
        thousands = .none
    case ",", "\u{066C}":
        thousands = .comma
    case ".":
        thousands = .period
    default:
        thousands = .space
    }
    if thousands.rawValue == decimal.rawValue {
        thousands = .space
    }
    return NumberFormat(thousandsSeparator: thousands, decimalSeparator: decimal)
}

/// The number format for the Mac's region, as it is now: the nearest of the
/// six to its separators.
public var defaultNumberFormat: NumberFormat {
    nearestNumberFormat(to: .autoupdatingCurrent)
}

/// The key in the standard user defaults.
private let numberFormatKey = "numberFormat"

/// Get the user's preferred number format.
public func getNumberFormatPreference() -> NumberFormat {
    guard let key = UserDefaults.standard.string(forKey: numberFormatKey), !key.isEmpty else {
        return defaultNumberFormat
    }
    return numberFormatFromKey(key)
}

/// Serialize a number format to a string key for use in pickers and
/// storage.
public func numberFormatToKey(_ fmt: NumberFormat) -> String {
    "\(fmt.thousandsSeparator.rawValue)|\(fmt.decimalSeparator.rawValue)"
}

/// Deserialize a number format key back to a `NumberFormat`, returning the
/// default if the key is not recognized.
public func numberFormatFromKey(_ key: String) -> NumberFormat {
    numberFormats.first { numberFormatToKey($0) == key } ?? defaultNumberFormat
}
