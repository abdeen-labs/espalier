// Ported from desktop/app/src/ui/lib/round.ts

import EspalierSupport
import Foundation

/// Round a number to the desired number of decimals.
///
/// See https://stackoverflow.com/a/11832950/2114
///
/// - Parameters:
///   - value: The number to round to the number of decimals specified
///   - decimals: The number of decimals to round to. Ex:
///     2: 1234.56789 => 1234.57
///     3: 1234.56789 => 1234.568
public func round(_ value: Double, _ decimals: Int) -> Double {
    if decimals <= 0 {
        return JSCompat.mathRound(value)
    }

    let factor = pow(10, Double(decimals))
    return JSCompat.mathRound((value + Double.ulpOfOne) * factor) / factor
}
