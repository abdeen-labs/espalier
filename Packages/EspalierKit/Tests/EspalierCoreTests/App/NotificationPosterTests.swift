// The notification poster's permission: a denial isn't kept, so allowing
// notifications later takes effect at the next post; the user is asked
// once, while they haven't been.

@testable import EspalierCore
import Foundation
import Synchronization
import Testing
import UserNotifications

/// A notification center whose permission the test sets.
private final class FakeNotificationCenter: NotificationCenterClient {
    private struct State {
        var status: UNAuthorizationStatus
        var grantsRequest: Bool
        var requests = 0
        var statusReads = 0
        var delivered: [UserNotification] = []
    }

    private let state: Mutex<State>

    init(status: UNAuthorizationStatus, grantsRequest: Bool = true) {
        state = Mutex(State(status: status, grantsRequest: grantsRequest))
    }

    var status: UNAuthorizationStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var requests: Int {
        state.withLock { $0.requests }
    }

    var statusReads: Int {
        state.withLock { $0.statusReads }
    }

    var delivered: [String] {
        state.withLock { $0.delivered.map(\.title) }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        state.withLock { state in
            state.statusReads += 1
            return state.status
        }
    }

    func requestAuthorization() async throws -> Bool {
        state.withLock { state in
            state.requests += 1
            state.status = state.grantsRequest ? .authorized : .denied
            return state.grantsRequest
        }
    }

    func add(_ notification: UserNotification) async throws {
        state.withLock { $0.delivered.append(notification) }
    }
}

@Suite("Notification poster")
struct NotificationPosterTests {
    @Test("a denial isn't kept: once the user allows notifications, the next one goes out")
    func deniedThenAllowed() async {
        let center = FakeNotificationCenter(status: .denied)
        let poster = UserNotificationCenterPoster(center: center)

        await poster.post(UserNotification(title: "First", body: ""))
        #expect(center.delivered.isEmpty)
        #expect(center.requests == 0)

        // Allowed in System Settings (or Settings ▸ Notifications).
        center.status = .authorized
        await poster.post(UserNotification(title: "Second", body: ""))
        #expect(center.delivered == ["Second"])

        // A granted permission is kept.
        let reads = center.statusReads
        await poster.post(UserNotification(title: "Third", body: ""))
        #expect(center.delivered == ["Second", "Third"])
        #expect(center.statusReads == reads)
    }

    @Test("the user is asked once, while they haven't been; a refusal is asked about no more")
    func asksOnce() async {
        let granting = FakeNotificationCenter(status: .notDetermined)
        let poster = UserNotificationCenterPoster(center: granting)
        await poster.post(UserNotification(title: "First", body: ""))
        await poster.post(UserNotification(title: "Second", body: ""))
        #expect(granting.requests == 1)
        #expect(granting.delivered == ["First", "Second"])

        let refusing = FakeNotificationCenter(status: .notDetermined, grantsRequest: false)
        let refused = UserNotificationCenterPoster(center: refusing)
        await refused.post(UserNotification(title: "First", body: ""))
        await refused.post(UserNotification(title: "Second", body: ""))
        #expect(refusing.requests == 1)
        #expect(refusing.delivered.isEmpty)
    }

    @Test("provisional permission delivers")
    func provisional() async {
        let center = FakeNotificationCenter(status: .provisional)
        await UserNotificationCenterPoster(center: center).post(UserNotification(title: "Quiet", body: ""))
        #expect(center.delivered == ["Quiet"])
    }
}
