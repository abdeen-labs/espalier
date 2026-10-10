// URL scheme handlers for tests. Nothing is looked up in, or changed in, the
// Mac's Launch Services.

import EspalierCore
import Foundation

/// Records the default handlers set and the links opened in other apps,
/// finding only the applications a test installs.
@MainActor
public final class RecordingURLSchemeHandlers: URLSchemeHandlerService {
    /// A scheme's default handler, as set.
    public struct DefaultHandler: Sendable, Equatable {
        public let scheme: String
        public let applicationURL: URL

        public init(scheme: String, applicationURL: URL) {
            self.scheme = scheme
            self.applicationURL = applicationURL
        }
    }

    /// A link opened in an application.
    public struct OpenedLink: Sendable, Equatable {
        public let url: URL
        public let applicationURL: URL

        public init(url: URL, applicationURL: URL) {
            self.url = url
            self.applicationURL = applicationURL
        }
    }

    public let espalierURL = URL(filePath: "/Applications/Espalier.app", directoryHint: .isDirectory)
    /// Where `installGitHubDesktop()` puts GitHub Desktop.
    public let gitHubDesktopURL = URL(filePath: "/Applications/GitHub Desktop.app", directoryHint: .isDirectory)

    /// The installed applications, by bundle identifier.
    public var installed: [String: URL] = [:]
    /// The default handlers set, in order.
    public private(set) var defaultHandlers: [DefaultHandler] = []
    /// The default handlers asked for, in order, including the ones that
    /// failed or are held.
    public private(set) var requestedHandlers: [DefaultHandler] = []
    /// The application that opens each scheme's links: the last one set,
    /// or one a test puts here for another app that took them.
    public var defaultApplications: [String: URL] = [:]
    /// The links opened in other applications, in order.
    public private(set) var openedLinks: [OpenedLink] = []
    /// What setting a default handler throws, if anything; nothing is
    /// recorded then.
    public var setDefaultFailure: (any Error)?
    /// What opening a link throws, if anything; nothing is recorded then.
    public var openFailure: (any Error)?
    /// Whether setting a default handler waits for `releaseHeldChanges()`.
    public var holdsChanges = false

    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Installs GitHub Desktop at `gitHubDesktopURL`.
    public func installGitHubDesktop() {
        installed[GitHubDesktopLinks.bundleIdentifier] = gitHubDesktopURL
    }

    public func applicationURL(bundleIdentifier: String) -> URL? {
        installed[bundleIdentifier]
    }

    public func defaultApplicationURL(toOpenURLsWithScheme scheme: String) -> URL? {
        defaultApplications[scheme]
    }

    public func isEspalier(_ applicationURL: URL) -> Bool {
        applicationURL == espalierURL
    }

    public func setDefaultApplication(at applicationURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        requestedHandlers.append(DefaultHandler(scheme: scheme, applicationURL: applicationURL))
        if holdsChanges {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                held.append(continuation)
                let waiters = heldWaiters
                heldWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        if let setDefaultFailure {
            throw setDefaultFailure
        }
        defaultHandlers.append(DefaultHandler(scheme: scheme, applicationURL: applicationURL))
        defaultApplications[scheme] = applicationURL
    }

    public func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
        if let openFailure {
            throw openFailure
        }
        openedLinks.append(OpenedLink(url: url, applicationURL: applicationURL))
    }

    /// Waits until a change is held.
    public func waitUntilHeld() async {
        guard held.isEmpty else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            heldWaiters.append(continuation)
        }
    }

    /// Stops holding changes and lets the held ones go on.
    public func releaseHeldChanges() {
        holdsChanges = false
        let continuations = held
        held = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}
