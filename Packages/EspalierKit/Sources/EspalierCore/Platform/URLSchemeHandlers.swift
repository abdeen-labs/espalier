// Which app opens a URL scheme's links, and opening a link in a chosen app,
// through Launch Services.

import AppKit

/// Launch Services' handlers for URL schemes: finding an application, which
/// application opens a scheme's links, making one the default for a scheme,
/// and opening a link in one whatever the default is.
///
/// Tests inject their own, so they never change what opens links on the Mac
/// that runs them.
@MainActor
public protocol URLSchemeHandlerService: Sendable {
    /// Espalier's own application bundle.
    var espalierURL: URL { get }

    /// The application Launch Services prefers for this bundle identifier,
    /// or nil when no application has it, or when the one Launch Services
    /// remembers has since been deleted.
    func applicationURL(bundleIdentifier: String) -> URL?

    /// The application that opens links whose scheme is `scheme`, or nil
    /// when no application can.
    func defaultApplicationURL(toOpenURLsWithScheme scheme: String) -> URL?

    /// Whether the application at `applicationURL` is Espalier: this copy,
    /// or another copy with its bundle identifier.
    func isEspalier(_ applicationURL: URL) -> Bool

    /// Makes the application at `applicationURL` the default for links whose
    /// scheme is `scheme`.
    func setDefaultApplication(at applicationURL: URL, toOpenURLsWithScheme scheme: String) async throws

    /// Opens `url` in the application at `applicationURL`, whichever
    /// application is the default for its scheme.
    func open(_ url: URL, withApplicationAt applicationURL: URL) async throws
}

/// The handlers, through `NSWorkspace`.
public struct LaunchServicesURLSchemeHandlers: URLSchemeHandlerService {
    public let espalierURL: URL
    /// Espalier's bundle identifier; nil for a process without one.
    private let espalierBundleIdentifier: String?

    /// - Parameter bundle: Espalier's bundle.
    public init(bundle: Bundle = .main) {
        espalierURL = bundle.bundleURL
        espalierBundleIdentifier = bundle.bundleIdentifier
    }

    public func applicationURL(bundleIdentifier: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            return nil
        }
        return url
    }

    public func defaultApplicationURL(toOpenURLsWithScheme scheme: String) -> URL? {
        guard let link = URL(string: "\(scheme)://") else {
            return nil
        }
        return NSWorkspace.shared.urlForApplication(toOpen: link)
    }

    public func isEspalier(_ applicationURL: URL) -> Bool {
        if Self.normalizedPath(applicationURL) == Self.normalizedPath(espalierURL) {
            return true
        }
        guard let espalierBundleIdentifier else {
            return false
        }
        return Bundle(url: applicationURL)?.bundleIdentifier == espalierBundleIdentifier
    }

    /// The URL's path with symbolic links resolved and no trailing slash.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    public func setDefaultApplication(at applicationURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: scheme) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { @Sendable _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
