// Ported from desktop/app/src/ui/lib/bytes.ts

private let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"]

/// Formats a number of bytes into a human readable string.
///
/// This method will uses the IEC representation for orders
/// of magnitude (KiB/MiB rather than MB/KB) in order to match
/// the format that Git uses.
///
/// Example output:
///
///    23 GiB
///   -43 B
///
/// - Parameters:
///   - bytes: The number of bytes to reformat into human readable form
///   - decimals: The number of decimals to round the result to, defaults to
///     zero
///   - numberFormat: The separators to use, defaulting to the user's
///     preferred number format.
public func formatBytes(_ bytes: Double, _ decimals: Int = 0, numberFormat: NumberFormat? = nil) -> String {
    formatCompactNumber(
        bytes,
        CompactFormatOptions(
            decimals: decimals,
            base: 1024,
            units: units,
            unitSeparator: " ",
            numberFormat: numberFormat
        )
    )
}
