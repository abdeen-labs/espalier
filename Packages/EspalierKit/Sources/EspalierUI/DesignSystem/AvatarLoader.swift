// Ported in part from desktop/app/src/ui/lib/avatar.tsx
//
// Who an avatar shows is GitHubKit's `AvatarUser`. An avatar tries each
// source that can supply one, in order, and is a monogram only when none
// can.
// - The API's avatar URL when it's known (accounts, reviewers, pull request
//   authors, bots resolved below), with `s` set; not on an Enterprise
//   Server, where it sits behind private mode.
// - Bots: GitHub.com's known bots by their apps' avatars, matched by their
//   noreply addresses; any other `[bot]` noreply login through the API's
//   user lookup, with an account signed in at the repository's endpoint,
//   kept per endpoint and email (ghe.com's for 50 minutes). On ghe.com every
//   noreply login resolves this way: its email form needs an avatar token
//   Espalier can't get.
// - By email: GitHub.com's (a noreply address with a user ID by that ID),
//   also for repositories with no GitHub host (`endpoint ??
//   getDotComAPIEndpoint()`), so GitHub sees the emails of the authors whose
//   commits are browsed; an Enterprise Server 3.0 or later through its
//   avatars API, with the token of an account signed in at its origin, or
//   without one (servers outside private mode answer). Older servers have no
//   such API.
// GitHub's stand-in for an email it doesn't know (one generated image, the
// same for everyone) isn't an avatar: the monogram shows, and the answer is
// kept like a loaded image. A failure isn't tried again for 5 minutes, or
// until the network comes back. A token goes only to its own origin, never
// across a redirect to another.

import CryptoKit
import EspalierSupport
import Foundation
import GitHubKit
import ImageIO
import Network
import SwiftUI
import Synchronization
import os

nonisolated private let logger = Log.logger(category: "avatars")

/// Loads avatars. Views get the loader from the environment, so snapshots
/// use monograms and each window can have a loader that knows its accounts.
nonisolated public protocol AvatarLoading: Sendable {
    /// The image, if it's already loaded (for table cells, without waiting).
    func cachedImage(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) -> CGImage?

    /// Loads the image, or returns nil when the avatar is a monogram.
    func image(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) async -> CGImage?
}

/// Never loads anything: every avatar is a monogram. Snapshots and tests
/// use it.
nonisolated public struct MonogramAvatarLoader: AvatarLoading {
    public init() {}

    public func cachedImage(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        nil
    }

    public func image(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        nil
    }
}

// MARK: Where an avatar comes from

/// The URLs to try for `user`'s avatar at `size` pixels, in order: the
/// API's avatar URL when it's known and not an Enterprise Server's, then the
/// email form of the user's server, or GitHub.com's when the repository has
/// no GitHub host. Empty for an Enterprise Server without the avatars API.
///
/// A GitHub.com noreply address with a user ID loads by that ID, and ghe.com
/// has no email form (it needs an avatar token), so its API avatar URL is
/// tried on its own.
nonisolated public func avatarURLCandidates(for user: AvatarUser, size: Int, supportsAvatarsAPI: Bool) -> [URL] {
    let endpoint = user.endpoint ?? getDotComAPIEndpoint()
    var candidates: [URL] = []
    // The API's URLs are on load-balanced avatar hosts; an Enterprise
    // Server's are behind private mode.
    if !isGHES(endpoint), let avatarURL = user.avatarURL, let url = sizedAvatarURL(avatarURL, size: size) {
        candidates.append(url)
    }
    if isGHES(endpoint), !supportsAvatarsAPI {
        // An old Enterprise Server: nothing gets past private mode.
        return []
    }
    if !isGHE(endpoint), !user.email.isEmpty, let url = emailAvatarURL(email: user.email, endpoint: endpoint, size: size) {
        candidates.append(url)
    }
    return candidates
}

/// `string` with its `s` query parameter set to `size`, the API's avatar
/// URLs being sized for GitHub's pages.
nonisolated func sizedAvatarURL(_ string: String, size: Int) -> URL? {
    guard var components = URLComponents(string: string), components.scheme != nil else {
        return nil
    }
    var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "s" }
    items.append(URLQueryItem(name: "s", value: String(size)))
    components.percentEncodedQueryItems = items
    return components.url
}

/// The avatar of an email on `endpoint`'s server: an Enterprise Server's
/// avatars API, or GitHub.com's (by user ID for a noreply address that has
/// one).
nonisolated func emailAvatarURL(email: String, endpoint: String, size: Int) -> URL? {
    let base: String
    if isGHES(endpoint) {
        // Enterprise endpoints have no trailing slash
        // (https://github.example.com/api/v3).
        base = (endpoint.hasSuffix("/") ? endpoint : "\(endpoint)/") + "enterprise/avatars/u/e"
    } else if let id = parseStealthEmail(email, endpoint)?.id {
        return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(size)")
    } else {
        base = "https://avatars.githubusercontent.com/u/e"
    }
    guard var components = URLComponents(string: base) else {
        return nil
    }
    components.percentEncodedQuery = "email=\(formURLEncoded(email))&s=\(size)"
    return components.url
}

/// `string` as `URLSearchParams` writes a value: letters, digits, and `*-._`
/// as they are, a space as `+`, everything else percent-encoded, so a `+` in
/// an address isn't read as a space.
nonisolated func formURLEncoded(_ string: String) -> String {
    let hex = Array("0123456789ABCDEF".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(string.utf8.count)
    for byte in string.utf8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
            bytes.append(byte)
        case UInt8(ascii: " "):
            bytes.append(UInt8(ascii: "+"))
        default:
            bytes += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// The bot cache's key: "<endpoint>:<email>", GitHub.com's endpoint when
/// the repository has no GitHub host.
nonisolated func avatarLookupKey(_ user: AvatarUser) -> String {
    "\(user.endpoint ?? getDotComAPIEndpoint()):\(user.email)"
}

/// GitHub.com's known bots under both forms of their noreply addresses, by
/// lookup key.
nonisolated let knownBotAvatarURLs: [String: String] = {
    var urls: [String: String] = [:]
    for bot in knownDotComBots {
        for email in [getStealthEmailForUser(bot.userId, bot.login, bot.endpoint), getLegacyStealthEmailForUser(bot.login, bot.endpoint)] {
            urls["\(bot.endpoint):\(email)"] = bot.avatarURL
        }
    }
    return urls
}()

/// The login whose avatar URL the API's user lookup gives: a bot's noreply
/// login, or on ghe.com any noreply login.
/// Nil when the avatar URL is known or the repository has no GitHub host.
nonisolated func avatarLookupLogin(for user: AvatarUser) -> String? {
    guard user.avatarURL == nil, let endpoint = user.endpoint, let login = parseStealthEmail(user.email, endpoint)?.login else {
        return nil
    }
    return login.hasSuffix("[bot]") || isGHE(endpoint) ? login : nil
}

/// GitHub's stand-in for an email it doesn't know: one generated image for
/// everyone, a 420-pixel PNG whatever size is asked, whose ETag is the
/// SHA-256 of its bytes.
nonisolated enum GitHubAvatarStandIn {
    static let digest = "1506265dd79492985d428bf3ac115e873c30eedde97749ace57dff5a0020a0a2"

    /// Whether a response is the stand-in: by its ETag, or by its body's
    /// SHA-256 when it has none.
    static func matches(etag: String?, body: Data, digest: String = digest) -> Bool {
        if let etag, !etag.isEmpty {
            var tag = Substring(etag.trimmingCharacters(in: .whitespaces))
            if tag.hasPrefix("W/") {
                tag = tag.dropFirst(2)
            }
            return tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() == digest
        }
        return SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() == digest
    }
}

// MARK: Tokens

/// Which image requests carry a token: GitHub Enterprise's avatars API and
/// repository assets, with the token of the account signed in at the
/// request's own origin.
nonisolated enum ImageAuthorization {
    /// The signed-in accounts' tokens by origin, GitHub.com's API token for
    /// github.com too, where private images live.
    static func tokens(for accounts: [Account]) -> [String: String] {
        var tokens: [String: String] = [:]
        for account in accounts where !account.token.isEmpty {
            if let origin = origin(of: account.endpoint) {
                tokens[origin] = account.token
            }
        }
        // If we have a token for api.github.com, add another entry with the
        // same token for github.com. This is necessary for private image
        // URLs.
        if let apiOrigin = origin(of: getDotComAPIEndpoint()), let token = tokens[apiOrigin],
           let htmlOrigin = origin(of: getHTMLURL(getDotComAPIEndpoint())) {
            tokens[htmlOrigin] = token
        }
        return tokens
    }

    /// The `Authorization` header for a request to `url`, if it gets one.
    static func header(for url: URL, tokens: [String: String]) -> String? {
        guard let origin = origin(of: url.absoluteString), let token = tokens[origin] else {
            return nil
        }
        let path = url.path(percentEncoded: true)
        guard isEnterpriseAvatarPath(path) || isGitHubRepoAssetPath(path) else {
            return nil
        }
        return "token \(token)"
    }

    static func isEnterpriseAvatarPath(_ pathname: String) -> Bool {
        pathname.hasPrefix("/api/v3/enterprise/avatars/")
    }

    /// Matches paths like `/<owner>/<repo>/assets/<userID>/<guid>`, or
    /// `/user-attachments/assets/<guid>`.
    static func isGitHubRepoAssetPath(_ pathname: String) -> Bool {
        pathname.wholeMatch(of: /\/[^\/]+\/[^\/]+\/assets\/[^\/]+\/[^\/]+\/?/) != nil
            || pathname.wholeMatch(of: /\/user-attachments\/assets\/[^\/]+\/?/) != nil
    }

    /// `new URL(string).origin`, or nil when it isn't an http(s) URL.
    static func origin(of string: String) -> String? {
        guard let url = try? JSURL(string), url.protocol == "https:" || url.protocol == "http:" else {
            return nil
        }
        return url.origin
    }
}

/// Drops the `Authorization` header from a redirect to another origin
/// (GitHub sends private assets to signed URLs on other hosts).
nonisolated final class SameOriginAuthorization: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirect(request, from: task.originalRequest))
    }

    /// The redirected request, without the token when it goes to another
    /// origin.
    static func redirect(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        var redirected = request
        let from = original?.url.flatMap { ImageAuthorization.origin(of: $0.absoluteString) }
        let to = request.url.flatMap { ImageAuthorization.origin(of: $0.absoluteString) }
        if from == nil || from != to {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }
}

// MARK: The network coming back

/// Tells the loaders when the network comes back, so failures are tried
/// again at once, then posts `GitHubAvatarLoader.networkDidReturn` on the
/// main thread for the views. One watches the system's network path for the
/// process; tests drive their own.
nonisolated final class NetworkReturnMonitor: Sendable {
    /// The process's monitor, watching the network path from its first
    /// registration on.
    static let shared = NetworkReturnMonitor(watchesPath: true)

    private struct State {
        var lastSatisfied: Bool?
        var nextID: UInt64 = 0
        var callbacks: [UInt64: @Sendable () -> Void] = [:]
        var monitor: NWPathMonitor?
    }

    private let watchesPath: Bool
    private let state = Mutex(State())

    init(watchesPath: Bool) {
        self.watchesPath = watchesPath
    }

    deinit {
        state.withLock { $0.monitor?.cancel() }
    }

    /// Calls `callback` whenever the network comes back, until the
    /// registration goes.
    func register(_ callback: @escaping @Sendable () -> Void) -> NetworkReturnRegistration {
        let (id, startsMonitor) = state.withLock { state -> (UInt64, Bool) in
            state.nextID &+= 1
            state.callbacks[state.nextID] = callback
            return (state.nextID, watchesPath && state.monitor == nil)
        }
        if startsMonitor {
            startMonitor()
        }
        return NetworkReturnRegistration { [weak self] in
            self?.state.withLock { _ = $0.callbacks.removeValue(forKey: id) }
        }
    }

    private func startMonitor() {
        let monitor = NWPathMonitor()
        let started = state.withLock { state -> Bool in
            guard state.monitor == nil else {
                return false
            }
            state.monitor = monitor
            return true
        }
        guard started else {
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(satisfied: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "com.espalier.avatars.network"))
    }

    /// A new network path: satisfied after one that wasn't means the
    /// network came back.
    func pathChanged(satisfied: Bool) {
        let (returned, callbacks) = state.withLock { state -> (Bool, [@Sendable () -> Void]) in
            defer { state.lastSatisfied = satisfied }
            guard satisfied, state.lastSatisfied == false else {
                return (false, [])
            }
            return (true, Array(state.callbacks.values))
        }
        guard returned else {
            return
        }
        logger.info("The network came back; avatars that failed try again")
        for callback in callbacks {
            callback()
        }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: GitHubAvatarLoader.networkDidReturn, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: GitHubAvatarLoader.networkDidReturn, object: self)
            }
        }
    }
}

/// Ends a `NetworkReturnMonitor` registration when it goes.
nonisolated final class NetworkReturnRegistration: Sendable {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit {
        cancel()
    }
}

// MARK: Loading

/// Loads avatars by the rule above, downsampled and cached (an `NSCache`
/// of decoded images), off the main thread. Without accounts it loads what
/// needs none; `setAccounts(_:)` adds Enterprise Server tokens and the
/// API's user lookup.
nonisolated public final class GitHubAvatarLoader: AvatarLoading, @unchecked Sendable {
    /// A loader for windows that don't set their own (the windows' own
    /// loaders know their accounts).
    public static let shared = GitHubAvatarLoader()

    /// Posted on the main thread when the network comes back, after the
    /// loaders forgot their failures: avatars showing monograms try again.
    /// The object is the monitor that saw it.
    public static let networkDidReturn = Notification.Name("EspalierAvatarNetworkDidReturn")

    /// How long an avatar that failed isn't tried again; failed lookups
    /// too.
    static let retryInterval: TimeInterval = 5 * 60
    /// How long a ghe.com user lookup is kept.
    static let gheLookupLifetime: TimeInterval = 50 * 60

    private struct Lookup {
        var avatarURL: String
        /// When it's looked up again (ghe.com's); nil: never.
        var expires: Date?
    }

    private struct State {
        /// Tokens by origin, for the Enterprise avatars API.
        var tokens: [String: String] = [:]
        /// Tokens by endpoint, for the API's user lookup.
        var endpointTokens: [String: String] = [:]
        /// When each avatar URL last failed.
        var failures: [URL: Date] = [:]
        /// Avatar URLs the user lookup gave, by lookup key.
        var lookups: [String: Lookup] = [:]
        /// When each lookup last failed.
        var failedLookups: [String: Date] = [:]
    }

    private let session: URLSession
    private let runtime: GitHubRuntime?
    private let now: @Sendable () -> Date
    private let supportsAvatarsAPI: @Sendable (String) -> Bool
    /// Loaded images by URL; an empty box is GitHub's stand-in.
    private let images: any ImageCache
    private let state = Mutex(State())
    private let fetches = InFlightLoads<URL, AvatarFetch>()
    private let userLookups = InFlightLoads<String, String?>()
    private var networkRegistration: NetworkReturnRegistration?

    /// - Parameters:
    ///   - session: Where images are requested.
    ///   - runtime: The GitHub runtime for user lookups (nil: the current
    ///     one).
    ///   - now: The clock.
    ///   - supportsAvatarsAPI: Whether an Enterprise Server has the avatars
    ///     API (3.0 or later).
    ///   - network: Tells the loader when the network comes back.
    ///   - images: Where loaded images are kept.
    public convenience init(session: URLSession = .shared, runtime: GitHubRuntime? = nil) {
        self.init(session: session, runtime: runtime, now: { Date() }, supportsAvatarsAPI: nil, network: .shared)
    }

    init(
        session: URLSession,
        runtime: GitHubRuntime?,
        now: @escaping @Sendable () -> Date,
        supportsAvatarsAPI: (@Sendable (String) -> Bool)?,
        network: NetworkReturnMonitor?,
        images: any ImageCache = EvictingImageCache(countLimit: 2_000)
    ) {
        self.session = session
        self.runtime = runtime
        self.now = now
        self.supportsAvatarsAPI = supportsAvatarsAPI ?? { GitHubKit.supportsAvatarsAPI($0, runtime: runtime ?? .current) }
        self.images = images
        networkRegistration = network?.register { [weak self] in
            self?.forgetFailures()
        }
    }

    // MARK: Accounts

    /// Uses `accounts`' tokens from now on: each for its own origin's
    /// Enterprise avatars, and for the user lookup on its endpoint. Images
    /// loaded with the old tokens and failures are forgotten.
    public func setAccounts(_ accounts: [Account]) {
        let tokens = ImageAuthorization.tokens(for: accounts)
        var endpointTokens: [String: String] = [:]
        for account in accounts where !account.token.isEmpty && endpointTokens[account.endpoint] == nil {
            endpointTokens[account.endpoint] = account.token
        }
        let changed = state.withLock { state -> Bool in
            guard state.tokens != tokens || state.endpointTokens != endpointTokens else {
                return false
            }
            state.tokens = tokens
            state.endpointTokens = endpointTokens
            state.failures.removeAll()
            state.failedLookups.removeAll()
            return true
        }
        if changed {
            images.removeAllObjects()
        }
    }

    /// Forgets failed avatars and lookups, so they're tried again at once
    /// (the network came back).
    func forgetFailures() {
        state.withLock { state in
            state.failures.removeAll()
            state.failedLookups.removeAll()
        }
    }

    // MARK: Avatars

    public func cachedImage(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let size = Self.pixels(pointSize, scale)
        let user = knownUser(identity, includingExpired: true)
        let now = now()
        for url in candidates(for: user, size: size) {
            if let box = images.object(forKey: url) {
                if let image = box.image {
                    return image
                }
                // GitHub's stand-in: no avatar here.
                continue
            }
            if hasFailedRecently(url, at: now) {
                continue
            }
            // Not loaded yet.
            return nil
        }
        return nil
    }

    public func image(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        let size = Self.pixels(pointSize, scale)
        let user = await resolvedUser(identity)
        for url in candidates(for: user, size: size) {
            if let box = images.object(forKey: url) {
                if let image = box.image {
                    return image
                }
                continue
            }
            if hasFailedRecently(url, at: now()) {
                continue
            }
            let authorization = state.withLock { ImageAuthorization.header(for: url, tokens: $0.tokens) }
            let fetched = await fetches.load(url) { [session] in
                await Self.fetch(url, authorization: authorization, session: session, maximumPixels: size)
            }
            switch fetched {
            case .image(let box):
                images.setObject(box, forKey: url)
                return box.image
            case .standIn:
                images.setObject(CGImageBox(nil), forKey: url)
            case .failure:
                let failedAt = now()
                state.withLock { $0.failures[url] = failedAt }
            }
        }
        return nil
    }

    /// The avatar's pixel size.
    private static func pixels(_ pointSize: CGFloat, _ scale: CGFloat) -> Int {
        Int((pointSize * scale).rounded(.up))
    }

    private func candidates(for user: AvatarUser, size: Int) -> [URL] {
        avatarURLCandidates(for: user, size: size, supportsAvatarsAPI: supportsAvatarsAPI(user.endpoint ?? getDotComAPIEndpoint()))
    }

    /// Whether `url` failed less than `retryInterval` ago; older failures
    /// are pruned.
    private func hasFailedRecently(_ url: URL, at now: Date) -> Bool {
        state.withLock { state in
            guard let failed = state.failures[url] else {
                return false
            }
            if now.timeIntervalSince(failed) < Self.retryInterval {
                return true
            }
            state.failures[url] = nil
            return false
        }
    }

    // MARK: Users

    /// `identity` with the avatar URL known without asking GitHub: a known
    /// bot's, or one the user lookup gave (an expired ghe.com lookup still
    /// finds an image already loaded).
    private func knownUser(_ identity: AvatarUser, includingExpired: Bool) -> AvatarUser {
        guard identity.avatarURL == nil else {
            return identity
        }
        let key = avatarLookupKey(identity)
        if let avatarURL = knownBotAvatarURLs[key] {
            return Self.user(identity, avatarURL: avatarURL)
        }
        let now = now()
        guard let lookup = state.withLock({ $0.lookups[key] }),
              includingExpired || lookup.expires.map({ now < $0 }) ?? true
        else {
            return identity
        }
        return Self.user(identity, avatarURL: lookup.avatarURL)
    }

    /// `identity` with its avatar URL, asking GitHub's user lookup for a
    /// bot's (or a ghe.com user's) when an account is signed in at its
    /// endpoint.
    private func resolvedUser(_ identity: AvatarUser) async -> AvatarUser {
        let known = knownUser(identity, includingExpired: false)
        guard known.avatarURL == nil, let endpoint = identity.endpoint, let login = avatarLookupLogin(for: identity) else {
            return known
        }
        let key = avatarLookupKey(identity)
        let started = now()
        let token = state.withLock { state -> String? in
            if let failed = state.failedLookups[key], started.timeIntervalSince(failed) < Self.retryInterval {
                return nil
            }
            return state.endpointTokens[endpoint]
        }
        guard let token else {
            return known
        }
        let runtime = runtime ?? .current
        let avatarURL = await userLookups.load(key) {
            await Self.lookUpAvatarURL(login: login, endpoint: endpoint, token: token, runtime: runtime)
        }
        let finished = now()
        state.withLock { state in
            if let avatarURL {
                state.lookups[key] = Lookup(avatarURL: avatarURL, expires: isGHE(endpoint) ? finished.addingTimeInterval(Self.gheLookupLifetime) : nil)
                state.failedLookups[key] = nil
            } else {
                state.failedLookups[key] = finished
            }
        }
        return avatarURL.map { Self.user(identity, avatarURL: $0) } ?? known
    }

    private static func user(_ identity: AvatarUser, avatarURL: String) -> AvatarUser {
        var user = identity
        user.avatarURL = avatarURL
        return user
    }

    /// The user's avatar URL from the API, or nil when there's no such user
    /// or the request failed.
    @concurrent
    private static func lookUpAvatarURL(login: String, endpoint: String, token: String, runtime: GitHubRuntime) async -> String? {
        do {
            let user = try await API(endpoint: endpoint, token: token, runtime: runtime).fetchUser(login: login)
            guard let avatarURL = user?.avatarURL, !avatarURL.isEmpty else {
                return nil
            }
            return avatarURL
        } catch {
            return nil
        }
    }

    // MARK: Requests

    /// What a request for an avatar gave.
    enum AvatarFetch: Sendable {
        case image(CGImageBox)
        /// GitHub's stand-in for an email it doesn't know.
        case standIn
        /// A network error, a status other than 2xx, or no image.
        case failure
    }

    /// Downloads and decodes an avatar, off the main actor. The token goes
    /// only to the URL's own origin.
    @concurrent
    private static func fetch(_ url: URL, authorization: String?, session: URLSession, maximumPixels: Int) async -> AvatarFetch {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request, delegate: SameOriginAuthorization())
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                logger.debug("An avatar didn't load: \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return .failure
            }
            if GitHubAvatarStandIn.matches(etag: response.value(forHTTPHeaderField: "ETag"), body: data) {
                return .standIn
            }
            guard let image = downsample(data, maximumPixels: maximumPixels) else {
                return .failure
            }
            return .image(CGImageBox(image))
        } catch {
            logger.debug("An avatar didn't load: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    /// Decodes and downsamples image data with ImageIO.
    static func downsample(_ data: Data, maximumPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixels, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A CGImage in an object, for `NSCache`.
nonisolated final class CGImageBox: @unchecked Sendable {
    let image: CGImage?

    init(_ image: CGImage?) {
        self.image = image
    }
}

/// Where an image loader keeps the images it loaded, by URL.
nonisolated protocol ImageCache: Sendable {
    func object(forKey url: URL) -> CGImageBox?
    func setObject(_ box: CGImageBox, forKey url: URL)
    func removeAllObjects()
}

/// The loaders' cache in the app: an `NSCache` of at most `countLimit`
/// images, which lets them go when memory runs low (they load again).
nonisolated final class EvictingImageCache: ImageCache, @unchecked Sendable {
    private let cache = NSCache<NSURL, CGImageBox>()

    init(countLimit: Int) {
        cache.countLimit = countLimit
    }

    func object(forKey url: URL) -> CGImageBox? {
        cache.object(forKey: url as NSURL)
    }

    func setObject(_ box: CGImageBox, forKey url: URL) {
        cache.setObject(box, forKey: url as NSURL)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

/// Shares one load per key between the views that ask for it.
actor InFlightLoads<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Never>] = [:]

    func load(_ key: Key, _ operation: @escaping @Sendable () async -> Value) async -> Value {
        if let task = tasks[key] {
            return await task.value
        }
        let task = Task { await operation() }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}

extension EnvironmentValues {
    /// Where avatars come from: monograms by default; each window sets its
    /// own loader.
    @Entry public var avatarLoader: any AvatarLoading = MonogramAvatarLoader()
}
