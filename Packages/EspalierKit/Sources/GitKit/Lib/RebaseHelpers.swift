// Ported from desktop/app/src/lib/rebase.ts

import EspalierSupport

/// Format rebase percentage to ensure it's a value between 0 and 1, but to also
/// constrain it to two significant figures, avoiding the remainder that comes
/// with floating point division.
public func formatRebaseValue(_ value: Double) -> Double {
    JSCompat.mathRound(clamp(value, 0, 1) * 100) / 100
}

/// Ensures that the returned value is at least min and at most (inclusive)
/// max. NaN passes through.
private func clamp(_ value: Double, _ min: Double, _ max: Double) -> Double {
    if value < min {
        return min
    } else if value > max {
        return max
    } else {
        return value
    }
}
