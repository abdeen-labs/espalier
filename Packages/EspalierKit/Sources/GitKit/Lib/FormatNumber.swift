// Ported from desktop/app/src/lib/format-number.ts

import EspalierSupport
import Foundation

/// `/\B(?=(\d{3})+(?!\d))/g`, the positions to put a thousands separator.
private let thousandsGroupingPattern = JSCompat.regex(#"\B(?=(?:[0-9]{3})+(?![0-9]))"#)

/// Format a number using the given separator configuration.
///
/// This is a simple formatter that handles integer and decimal parts with
/// configurable separators. It does not use a locale-aware number formatter.
///
/// - Parameters:
///   - value: The number to format
///   - fmt: The number format configuration with thousands and decimal
///     separators, defaults to the user's preferred format.
public func formatNumber(_ value: Double, _ fmt: NumberFormat? = nil) -> String {
    let fmt = fmt ?? getNumberFormatPreference()

    if !value.isFinite {
        return JSCompat.numberToString(value)
    }

    let isNegative = value < 0
    let abs = Swift.abs(value)
    let parts = JSCompat.split(JSCompat.numberToString(abs), ".")
    let intPart = parts[0]
    let decPart = parts.count > 1 ? parts[1] : nil
    var truncatedDecPart = decPart

    if let maximumFractionDigits = fmt.maximumFractionDigits, let decPart {
        // JavaScript's `slice(0, maximumFractionDigits)`, so a negative
        // count drops digits from the end.
        let count = decPart.unicodeScalars.count
        let end = maximumFractionDigits < 0 ? max(0, count + maximumFractionDigits) : min(count, maximumFractionDigits)
        let truncated = String(decPart.unicodeScalars.prefix(end))
        truncatedDecPart = truncated.isEmpty ? nil : truncated
    }

    // Insert the configured separator at the positions that are followed by
    // groups of exactly 3 digits.
    let range = NSRange(intPart.startIndex..<intPart.endIndex, in: intPart)
    let formattedInt = thousandsGroupingPattern.stringByReplacingMatches(
        in: intPart,
        range: range,
        withTemplate: NSRegularExpression.escapedTemplate(for: fmt.thousandsSeparator.rawValue)
    )

    let result = truncatedDecPart.map { "\(formattedInt)\(fmt.decimalSeparator.rawValue)\($0)" } ?? formattedInt

    return isNegative ? "-\(result)" : result
}

/// Options for `formatCompactNumber`.
public struct CompactFormatOptions: Sendable {
    /// Number of decimal places to display
    public var decimals: Int?

    /// The base to use for unit scaling.
    /// - 1000: SI/decimal units (k, m, b, t or KB, MB, GB)
    /// - 1024: IEC/binary units (KiB, MiB, GiB)
    public var base: Double?

    /// Custom unit suffixes to use. If not provided, defaults to:
    /// - For base 1000: ['', 'k', 'm', 'b', 't']
    /// - For base 1024: no default (must be provided)
    public var units: [String]?

    /// Whether to add a space between the number and the unit suffix.
    /// Defaults to false for the shorthand k/m/b/t units.
    public var unitSeparator: String?

    public var numberFormat: NumberFormat?

    public init(
        decimals: Int? = nil,
        base: Double? = nil,
        units: [String]? = nil,
        unitSeparator: String? = nil,
        numberFormat: NumberFormat? = nil
    ) {
        self.decimals = decimals
        self.base = base
        self.units = units
        self.unitSeparator = unitSeparator
        self.numberFormat = numberFormat
    }
}

private let defaultDecimalUnits = ["", "k", "m", "b", "t"]

/// Formats a number compactly, scaling it to the largest unit it reaches
/// (`1.5 KiB`, `12k`).
public func formatCompactNumber(_ value: Double, _ fmt: CompactFormatOptions? = nil) -> String {
    if !value.isFinite {
        return JSCompat.numberToString(value)
    }

    let abs = Swift.abs(value)
    let base = fmt?.base ?? 1000
    let units = fmt?.units ?? defaultDecimalUnits
    let unitSeparator = fmt?.unitSeparator ?? ""

    if abs < base {
        let result = formatNumber(value, fmt?.numberFormat)
        // For byte formatting, always show units even for small values
        if let unit = units.first, !unit.isEmpty {
            return "\(result)\(unitSeparator)\(unit)"
        }
        return result
    }

    let unitIx = min(units.count - 1, Int(floor(log(abs) / log(base))))

    let scaled = value / pow(base, Double(unitIx))

    // If the user didn't provide an explicit number of decimals to use, we'll
    // default to 1 decimal for numbers less than 10 and no decimals for numbers
    // 10 or greater. This is a common convention for compact number formatting
    // that balances precision with brevity.
    let decimals = fmt?.decimals ?? (Swift.abs(scaled) < 10 ? 1 : 0)

    let result = round(scaled, decimals)
    let unit = units.indices.contains(unitIx) ? units[unitIx] : "undefined"
    return "\(formatNumber(result, fmt?.numberFormat))\(unitSeparator)\(unit)"
}
