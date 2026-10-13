// Waiting for observable state without sleeping or spinning.

import TestSupport

/// Waits until `condition` holds, re-checking whenever the observable state
/// it reads changes. It has no deadline: a suite that waits has a
/// `.hangGuard(minutes:)`, which fails a test that would wait forever and
/// cancels it, which ends the wait.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    await waitUntilObserved(condition)
}
