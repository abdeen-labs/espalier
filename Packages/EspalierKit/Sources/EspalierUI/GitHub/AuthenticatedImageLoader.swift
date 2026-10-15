// Ported in part from desktop/app/src/main-process/authenticated-image-filter.ts
//
// Which requests carry the signed-in account's token: the ones GitHub serves
// privately (GitHub Enterprise Server's avatars API and repository assets,
// the images in pull request descriptions). The images in descriptions,
// reviews, and comments load here with that rule (the design system's
// `ImageAuthorization`), and avatars through a `GitHubAvatarLoader` that
// knows the window's accounts. A token goes only to the origin of the
// account it belongs to, never across a redirect to another origin. An
// image that failed isn't tried again for 5 minutes, or until the network
// comes back.

import CoreGraphics
import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import Observation
import Synchronization
import os

nonisolated private let logger = Log.logger(category: "images")

/// Loads images from the web for views that show them (pull request
/// descriptions, reviews, comments). The windows' avatar loader also loads
/// these; under a loader that doesn't (the monogram loader), images show
/// as links.
nonisolated public protocol RemoteImageLoading: Sendable {
    /// The image at `url`, if it's already loaded.
    func cachedImage(at url: URL, maximumPixels: Int) -> CGImage?

    /// Loads the image at `url`, downsampled to at most `maximumPixels` on
    /// its longer side, or nil when it can't be loaded.
    func image(at url: URL, maximumPixels: Int) async -> CGImage?
}

/// A window's image loader: avatars through its `GitHubAvatarLoader`, and
/// the images in pull request descriptions with the signed-in accounts'
/// tokens where GitHub serves them privately.
nonisolated public final class AuthenticatedImageLoader: AvatarLoading, RemoteImageLoading, @unchecked Sendable {
    /// How long an image that failed isn't tried again.
    static let retryInterval: TimeInterval = 5 * 60

    private let session: URLSession
    private let avatars: GitHubAvatarLoader
    private let now: @Sendable () -> Date
    /// The signed-in accounts' tokens, by origin.
    private let tokens = Mutex<[String: String]>([:])
    private let images: any ImageCache
    /// When each failed image last failed.
    private let failures = Mutex<[URL: Date]>([:])
    private let inFlight = InFlightLoads<URL, CGImageBox?>()
    private var networkRegistration: NetworkReturnRegistration?

    /// - Parameters:
    ///   - session: Where requests go.
    ///   - avatars: The window's avatars.
    public convenience init(session: URLSession = .shared, avatars: GitHubAvatarLoader) {
        self.init(session: session, avatars: avatars, now: { Date() }, network: .shared)
    }

    /// - Parameter images: Where loaded images are kept.
    init(
        session: URLSession,
        avatars: GitHubAvatarLoader,
        now: @escaping @Sendable () -> Date,
        network: NetworkReturnMonitor?,
        images: any ImageCache = EvictingImageCache(countLimit: 500)
    ) {
        self.session = session
        self.avatars = avatars
        self.now = now
        self.images = images
        networkRegistration = network?.register { [weak self] in
            self?.failures.withLock { $0.removeAll() }
        }
    }

    // MARK: Accounts

    /// Uses the tokens of `accounts` from now on, for images and avatars.
    /// Images loaded with the old tokens are forgotten.
    public func setAccounts(_ accounts: [Account]) {
        let map = ImageAuthorization.tokens(for: accounts)
        let changed = tokens.withLock { tokens -> Bool in
            defer { tokens = map }
            return tokens != map
        }
        if changed {
            images.removeAllObjects()
            failures.withLock { $0.removeAll() }
        }
        avatars.setAccounts(accounts)
    }

    /// Keeps the loader's tokens those of `accounts`' signed-in accounts.
    @MainActor
    public func follow(_ accounts: AccountsModel) {
        let current = withObservationTracking {
            accounts.accounts
        } onChange: { [weak self, weak accounts] in
            Task { @MainActor in
                guard let self, let accounts else {
                    return
                }
                self.follow(accounts)
            }
        }
        setAccounts(current)
    }

    // MARK: Avatars

    public func cachedImage(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        avatars.cachedImage(for: identity, pointSize: pointSize, scale: scale)
    }

    public func image(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        await avatars.image(for: identity, pointSize: pointSize, scale: scale)
    }

    // MARK: Images

    public func cachedImage(at url: URL, maximumPixels: Int) -> CGImage? {
        images.object(forKey: url)?.image
    }

    public func image(at url: URL, maximumPixels: Int) async -> CGImage? {
        if let image = images.object(forKey: url)?.image {
            return image
        }
        let started = now()
        let recentlyFailed = failures.withLock { failures in
            failures[url].map { started.timeIntervalSince($0) < Self.retryInterval } ?? false
        }
        guard !recentlyFailed, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let authorization = ImageAuthorization.header(for: url, tokens: tokens.withLock { $0 })
        let loaded = await inFlight.load(url) { [session] in
            await Self.fetch(url, authorization: authorization, session: session, maximumPixels: maximumPixels)
        }
        if let image = loaded?.image {
            images.setObject(CGImageBox(image), forKey: url)
            return image
        }
        let failedAt = now()
        failures.withLock { $0[url] = failedAt }
        return nil
    }

    /// Downloads and decodes an image, off the main actor. The token goes
    /// only to the URL's own origin: a redirect elsewhere (GitHub sends
    /// private assets to signed URLs on another host) drops it.
    @concurrent
    private static func fetch(_ url: URL, authorization: String?, session: URLSession, maximumPixels: Int) async -> CGImageBox? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request, delegate: SameOriginAuthorization())
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                logger.info("An image didn't load: \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return nil
            }
            return CGImageBox(GitHubAvatarLoader.downsample(data, maximumPixels: maximumPixels))
        } catch {
            logger.info("An image didn't load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension WindowContext {
    /// Makes the window's image loader one that knows the app's accounts
    /// and follows them (GitHub's actions do this for every window), with
    /// its own avatars, looked up through the app's GitHub runtime.
    func useAuthenticatedImageLoader() {
        let loader = AuthenticatedImageLoader(avatars: GitHubAvatarLoader(runtime: app.environment.gitHub))
        loader.follow(app.accounts)
        avatarLoader = loader
    }
}
