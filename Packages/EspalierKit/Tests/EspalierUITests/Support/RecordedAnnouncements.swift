// An announcer that records what VoiceOver would hear.

import Observation
@testable import EspalierUI

/// The messages posted through `announcer`, oldest first, as if VoiceOver
/// were on.
@MainActor @Observable
final class RecordedAnnouncements {
    private(set) var messages: [String] = []

    var announcer: Announcer {
        Announcer(isListening: { true }, post: { [self] message, _ in
            messages.append(message)
        })
    }
}
