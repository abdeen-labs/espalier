// VoiceOver announcements for what changes away from the focused element:
// how many items a filter leaves, a second after its text stops changing,
// and a commit starting and finishing. `Announcer` posts them; a window's
// views take it from the window's context.

import AppKit
import EspalierSupport
import SwiftUI

/// Asks VoiceOver to say a message.
struct Announcer: Sendable {
    /// How a message competes with what VoiceOver is saying.
    enum Priority: Sendable {
        /// Spoken after what VoiceOver is saying.
        case medium
        /// Interrupts what VoiceOver is saying.
        case high

        var level: NSAccessibilityPriorityLevel {
            switch self {
            case .medium: .medium
            case .high: .high
            }
        }
    }

    /// Whether VoiceOver is on: work done only to announce (counting a
    /// filter's results) is skipped when it's off.
    var isListening: @MainActor @Sendable () -> Bool
    var post: @MainActor @Sendable (String, Priority) -> Void

    func announce(_ message: String, priority: Priority = .high) {
        post(message, priority)
    }

    /// VoiceOver, through the key window (a popover or sheet in front),
    /// else the main window, else the app. Nothing is said in a process
    /// without an app (tests).
    static let voiceOver = Announcer(
        isListening: { NSWorkspace.shared.isVoiceOverEnabled },
        post: { message, priority in
            guard let app = NSApp else {
                return
            }
            let element: Any = app.keyWindow ?? app.mainWindow ?? app
            NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: priority.level.rawValue,
            ])
        }
    )
}

extension EnvironmentValues {
    /// Where the window's announcements go.
    @Entry var announcer: Announcer = .voiceOver
    /// The clock the window's views wait on (`AppEnvironment.scheduler`).
    @Entry var scheduler: any Scheduler = SystemScheduler()
}

// MARK: - Filter results

/// Tells VoiceOver how many items a filter matches once its text has been
/// still for a second: "No results", "1 result", "12 results". Each change
/// starts the wait again; an empty filter cancels it and says nothing.
/// Results still loading when the wait ends (a search running, a list
/// downloading) are announced as soon as they're in.
@MainActor
final class FilterResultsAnnouncer {
    private var waiting: Task<Void, Never>?

    /// Follows the filter's new `text`. `count` gives the number of
    /// matches, or nil while they load; it's read when the wait ends.
    func filterChanged(
        to text: String,
        count: @escaping @MainActor () -> Int?,
        scheduler: any Scheduler,
        announcer: Announcer
    ) {
        cancel()
        guard !text.isEmpty else {
            return
        }
        waiting = Task {
            do {
                try await scheduler.sleep(for: Timing.filterResultsAnnouncement)
            } catch {
                return
            }
            guard announcer.isListening() else {
                return
            }
            var matches: Int?
            await Observing.until {
                matches = count()
                return matches != nil
            }
            guard !Task.isCancelled, let matches else {
                return
            }
            announcer.announce(Self.message(forCount: matches))
        }
    }

    /// Stops waiting: nothing is announced.
    func cancel() {
        waiting?.cancel()
        waiting = nil
    }

    static func message(forCount count: Int) -> String {
        switch count {
        case 0: "No results"
        case 1: "1 result"
        default: "\(formatCount(count)) results"
        }
    }
}

extension View {
    /// Tells VoiceOver how many items `filter` matches, a second after its
    /// text stops changing (`FilterResultsAnnouncer`); the view going away
    /// cancels it. `count` gives the number of matches, or nil while they
    /// load.
    func announcesFilterResults(_ filter: String, count: @escaping @MainActor () -> Int?) -> some View {
        modifier(FilterResultsAnnouncement(filter: filter, count: count))
    }
}

private struct FilterResultsAnnouncement: ViewModifier {
    let filter: String
    let count: @MainActor () -> Int?
    @Environment(\.announcer) private var announcer
    @Environment(\.scheduler) private var scheduler
    @State private var announcement = FilterResultsAnnouncer()

    func body(content: Content) -> some View {
        content
            .onChange(of: filter) {
                announcement.filterChanged(to: filter, count: count, scheduler: scheduler, announcer: announcer)
            }
            .onDisappear {
                announcement.cancel()
            }
    }
}
