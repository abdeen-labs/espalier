// What captures of hosted views share: finding views in a host, waiting
// for what a view finishes after it shows, and whether a diff shows the
// document of its content. A diff builds its document off the main actor
// and installs it on the main actor, with nothing observable to say so;
// a wait checks again each time the main run loop has handled its work.

import AppKit
@testable import EspalierUI

extension NSView {
    /// The views of `type` in this view's subtree, this view included,
    /// depth first.
    func captureDescendants<T: NSView>(_ type: T.Type) -> [T] {
        ((self as? T).map { [$0] } ?? []) + subviews.flatMap { $0.captureDescendants(type) }
    }
}

extension DiffTableController {
    /// Whether the table shows the document of the content it was last
    /// given: one is shown and none is building (an install shows the
    /// latest content).
    var showsItsDocument: Bool {
        shownContent != nil && !isBuilding
    }
}

/// Whether every diff table in `view` shows the document of its content.
@MainActor
func diffsShowTheirDocuments(in view: NSView) -> Bool {
    view.captureDescendants(DiffTableView.self).allSatisfy { $0.controller?.showsItsDocument == true }
}

/// Waits until `condition` holds, checking it now and then each time the
/// main run loop has handled its work and is about to wait: after a
/// model's change lands, a document built off the main actor is installed,
/// or a view lays out. It has no deadline: a suite that waits has a
/// `.hangGuard(minutes:)`, which cancels the test, which ends the wait.
@MainActor
func waitUntilRunLoopIdle(_ condition: @escaping @MainActor () -> Bool) async {
    guard !condition() else {
        return
    }
    let wait = RunLoopWait()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            wait.start(condition, continuation: continuation)
        }
    } onCancel: {
        Task { @MainActor in
            wait.finish()
        }
    }
}

/// A run loop observer that resumes a continuation once its condition
/// holds, or once it's finished.
@MainActor
private final class RunLoopWait {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CFRunLoopObserver?

    func start(_ condition: @escaping @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if condition() {
                    self?.finish()
                }
            }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // A pass now, in case nothing else is about to wake the run loop.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func finish() {
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        continuation?.resume()
        continuation = nil
    }
}
