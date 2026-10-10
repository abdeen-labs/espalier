// Ported from desktop/app/src/models/formatting-preferences.ts
//
// Only the number format, which `formatNumber` reads (Git LFS progress shows
// formatted byte counts).

import Foundation

/// The country code of the user's locale, or nil.
private let localeCountryCode: String? = {
    // Two letters from A to Z.
    guard let region = Locale.current.region?.identifier else {
        return nil
    }
    let letters = region.unicodeScalars.prefix(2)
    guard letters.count == 2, letters.allSatisfy({ ("A"..."Z").contains($0) }) else {
        return nil
    }
    return String(String.UnicodeScalarView(letters))
}()

// Sourced from https://en.wikipedia.org/wiki/Decimal_separator
private let decimalPointCountries: Set<String> = [
    "AU", // Australia
    "BS", // Bahamas, The
    "BD", // Bangladesh
    "BW", // Botswana
    // British West Indies - No single ISO code (historical region, now multiple countries)
    "AI", // Anguilla (British Overseas Territory)
    "AG", // Antigua and Barbuda
    "BB", // Barbados
    "BM", // Bermuda (British Overseas Territory)
    "VG", // British Virgin Islands (British Overseas Territory)
    "KY", // Cayman Islands (British Overseas Territory)
    "DM", // Dominica
    "GD", // Grenada
    "JM", // Jamaica
    "MS", // Montserrat (British Overseas Territory)
    "KN", // Saint Kitts and Nevis
    "LC", // Saint Lucia
    "VC", // Saint Vincent and the Grenadines
    "TT", // Trinidad and Tobago
    "TC", // Turks and Caicos Islands (British Overseas Territory)
    "GY", // Guyana (formerly British Guiana)
    "BZ", // Belize (formerly British Honduras)
    "KH", // Cambodia
    "CA", // Canada
    "CN", // China
    "CY", // Cyprus
    "DO", // Dominican Republic
    "EG", // Egypt
    "SV", // El Salvador
    "ET", // Ethiopia
    "GH", // Ghana
    "GT", // Guatemala
    "HN", // Honduras
    "HK", // Hong Kong
    "IN", // India
    "IE", // Ireland
    "IL", // Israel
    "JP", // Japan
    "JO", // Jordan
    "KE", // Kenya
    "KP", // Korea, North
    "KR", // Korea, South
    "LY", // Libya
    "LI", // Liechtenstein
    "MO", // Macau
    "MY", // Malaysia
    "MV", // Maldives
    "MT", // Malta
    "MX", // Mexico
    "MM", // Myanmar
    "NA", // Namibia
    "NP", // Nepal
    "NZ", // New Zealand
    "NI", // Nicaragua
    "NG", // Nigeria
    "PK", // Pakistan
    "PA", // Panama
    "PH", // Philippines
    "RW", // Rwanda
    "QA", // Qatar
    "SA", // Saudi Arabia
    "SG", // Singapore
    "SO", // Somalia
    "LK", // Sri Lanka
    "CH", // Switzerland
    "SY", // Syria
    "TW", // Taiwan
    "TZ", // Tanzania
    "TH", // Thailand
    "UG", // Uganda
    "AE", // United Arab Emirates
    "GB", // United Kingdom
    "US", // United States
]

// Source: https://docs.oracle.com/cd/E19455-01/806-0169/overview-9/index.html
private let commaDigitGroupingCountries: Set<String> = ["US", "GB", "TH"]
private let spaceDigitGroupingCountries: Set<String> = ["CA", "DK", "FI", "SE", "FR", "DE"]
private let dotDigitGroupingCountries: Set<String> = ["IT", "NO", "ES"]

private func prefersDecimalPoint() -> Bool {
    guard let localeCountryCode else {
        return true
    }
    return decimalPointCountries.contains(localeCountryCode)
}

private func preferredThousandsSeparator() -> NumberFormat.ThousandsSeparator {
    guard let localeCountryCode else {
        return .none
    }

    if commaDigitGroupingCountries.contains(localeCountryCode) {
        return .comma
    }

    if spaceDigitGroupingCountries.contains(localeCountryCode) {
        return .space
    }

    if dotDigitGroupingCountries.contains(localeCountryCode) {
        return .period
    }

    // Default to no digit grouping because some locales (e.g. India) use digit
    // grouping sizes that we can't handle right now and I suppose it's better to
    // show ungrouped numbers than incorrectly grouped ones.
    return .none
}

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

/// The number format for the user's locale.
public let defaultNumberFormat = NumberFormat(
    thousandsSeparator: preferredThousandsSeparator(),
    decimalSeparator: prefersDecimalPoint() ? .period : .comma
)

/// The key in the standard user defaults.
private let numberFormatKey = "numberFormat"

/// Get the user's preferred number format.
public func getNumberFormatPreference() -> NumberFormat {
    guard let key = UserDefaults.standard.string(forKey: numberFormatKey), !key.isEmpty else {
        return defaultNumberFormat
    }
    return numberFormatFromKey(key)
}

/// Set the user's preferred number format.
public func setNumberFormatPreference(_ format: NumberFormat) {
    UserDefaults.standard.set(numberFormatToKey(format), forKey: numberFormatKey)
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
