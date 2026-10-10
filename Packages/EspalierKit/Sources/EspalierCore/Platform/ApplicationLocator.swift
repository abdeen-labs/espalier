import AppKit

/// Finds installed applications by bundle identifier.
///
/// Tests inject their own locator, so they never depend on what is installed.
public protocol ApplicationLocator: Sendable {
    /// The path of the application Launch Services prefers for this bundle
    /// identifier, or `nil` when no application has it.
    ///
    /// The path may no longer exist: Launch Services can remember an
    /// application that has since been deleted.
    func appPath(_ bundleIdentifier: String) -> String?
}

/// Finds applications through Launch Services.
public struct LaunchServicesApplicationLocator: ApplicationLocator {
    public init() {}

    public func appPath(_ bundleIdentifier: String) -> String? {
        // The documented replacement for
        // `absolutePathForAppBundleWithIdentifier:`, with the same heuristics
        // when several copies of an application share the identifier.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        // An application is a directory, so its URL's path ends with a slash.
        // Callers append to the path (`<path>/Contents/MacOS/kitty`) and show
        // it in error messages, so the slash is dropped.
        var path = url.path(percentEncoded: false)
        if path.utf8.count > 1, path.utf8.last == UInt8(ascii: "/") {
            path.removeLast()
        }
        return path
    }
}
