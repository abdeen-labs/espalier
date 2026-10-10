// GitHub's "Open with GitHub Desktop" links
// (`x-github-client://openRepo/<url>?branch=&pr=&filepath=`, and
// `github-mac://` on older pages), which Espalier opens once the user turns
// it on in Settings ▸ Integrations, and otherwise passes on to GitHub
// Desktop when it's installed. Links Espalier can't open (actions other than
// `openRepo`) go to GitHub Desktop when it's installed, whatever the switch
// says. Only the user changes the switch. While it's on, Espalier takes the
// links back from any other app that has them (GitHub Desktop makes itself
// their default app each time it launches).

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "github-desktop-links")

/// GitHub Desktop's link schemes and its application.
public enum GitHubDesktopLinks {
    /// The schemes of GitHub's "Open with GitHub Desktop" links:
    /// `x-github-client`, and `github-mac` on older pages.
    public static let schemes = ["x-github-client", "github-mac"]

    /// GitHub Desktop's bundle identifier.
    public static let bundleIdentifier = "com.github.GitHubClient"

    /// Whether `url` is one of GitHub Desktop's links (by its scheme,
    /// ignoring case).
    public static func isLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return schemes.contains(scheme)
    }
}

extension IntegrationsModel {
    /// Whether GitHub Desktop's links open in Espalier, as the switch shows
    /// it: the value being applied, else the setting.
    public var opensGitHubDesktopLinks: Bool {
        pendingOpenGitHubDesktopLinks ?? preferences.openGitHubDesktopLinks
    }

    /// Gives GitHub Desktop's links to Espalier (`isOn`) or back to GitHub
    /// Desktop, then saves the setting.
    ///
    /// On makes Espalier the default app for both schemes. Off makes GitHub
    /// Desktop their default again when it's installed; when it isn't, no
    /// other app can open them, so only the setting changes. The setting is
    /// written once every change is made, and a call while another is being
    /// applied does nothing. A running re-claim
    /// (`reclaimGitHubDesktopLinks()`) finishes the scheme it's changing
    /// first, and once the setting is written, re-claims run again after one
    /// failed.
    ///
    /// - Throws: `.other` with Launch Services' error when a change fails,
    ///   the setting unchanged; `.cancelled(.userCancelled)` when the user
    ///   declined it.
    public func setOpenGitHubDesktopLinks(_ isOn: Bool) async throws(OperationError) {
        guard pendingOpenGitHubDesktopLinks == nil else {
            return
        }
        let handlers = environment.urlSchemeHandlers
        let target: URL? = isOn
            ? handlers.espalierURL
            : handlers.applicationURL(bundleIdentifier: GitHubDesktopLinks.bundleIdentifier)
        pendingOpenGitHubDesktopLinks = isOn
        defer { pendingOpenGitHubDesktopLinks = nil }
        await gitHubDesktopLinksReclaimIdle()
        if let target {
            for scheme in GitHubDesktopLinks.schemes {
                do {
                    try await handlers.setDefaultApplication(at: target, toOpenURLsWithScheme: scheme)
                } catch {
                    logger.error("Couldn't set the app for \(scheme, privacy: .public) links: \(error.localizedDescription, privacy: .public)")
                    throw Self.linkHandlerError(error, isOn: isOn)
                }
            }
        }
        preferences.openGitHubDesktopLinks = isOn
        gitHubDesktopLinksReclaimFailed = false
    }

    /// Takes GitHub Desktop's links back while the setting is on: makes
    /// Espalier the default app again for each scheme whose links Launch
    /// Services opens in another app (GitHub Desktop took them back, or the
    /// user chose another app), or in none. The app calls it at launch and
    /// when it becomes active.
    ///
    /// It never changes the setting, asks nothing of Launch Services when
    /// Espalier opens both schemes, and does nothing while the switch's
    /// change is being applied or another re-claim runs. A change Launch
    /// Services refuses, or the user declines when the system asks, is
    /// logged and stops the re-claim; none runs again until the next launch
    /// or the switch's next change, so a declined one isn't asked again each
    /// time Espalier becomes active.
    public func reclaimGitHubDesktopLinks() {
        guard preferences.openGitHubDesktopLinks,
              pendingOpenGitHubDesktopLinks == nil,
              gitHubDesktopLinksReclaim == nil,
              !gitHubDesktopLinksReclaimFailed
        else {
            return
        }
        let handlers = environment.urlSchemeHandlers
        let schemes = GitHubDesktopLinks.schemes.filter { scheme in
            guard let handler = handlers.defaultApplicationURL(toOpenURLsWithScheme: scheme) else {
                return true
            }
            return !handlers.isEspalier(handler)
        }
        guard !schemes.isEmpty else {
            return
        }
        gitHubDesktopLinksReclaim = Task {
            defer { gitHubDesktopLinksReclaim = nil }
            for scheme in schemes {
                // Once the switch's change is being applied, it decides
                // where the links go.
                guard preferences.openGitHubDesktopLinks, pendingOpenGitHubDesktopLinks == nil else {
                    return
                }
                do {
                    try await handlers.setDefaultApplication(at: handlers.espalierURL, toOpenURLsWithScheme: scheme)
                } catch {
                    logger.error("Couldn't take \(scheme, privacy: .public) links back: \(error.localizedDescription, privacy: .public)")
                    gitHubDesktopLinksReclaimFailed = true
                    return
                }
                logger.info("Took \(scheme, privacy: .public) links back from another app")
            }
        }
    }

    /// Waits for a running re-claim to finish.
    func gitHubDesktopLinksReclaimIdle() async {
        await gitHubDesktopLinksReclaim?.value
    }

    private static func linkHandlerError(_ error: any Error, isOn: Bool) -> OperationError {
        let nsError = error as NSError
        if error is CancellationError || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
            return OperationError(.cancelled(.userCancelled), operation: .setLinkHandler, underlying: error)
        }
        let message = isOn
            ? "Couldn't set Espalier to open GitHub Desktop links."
            : "Couldn't set GitHub Desktop to open its links again."
        return OperationError(.other("\(message) \(error.localizedDescription)"), operation: .setLinkHandler, underlying: error)
    }
}

extension AppModel {
    /// Passes a GitHub Desktop link on to GitHub Desktop when it's installed
    /// and Espalier doesn't open the link: the setting is off, or the link
    /// isn't one Espalier can open (an action other than `openRepo`, such
    /// as GitHub Desktop's sign-in). Returns whether it did: Espalier
    /// handles every other link itself, since no other app can open one
    /// when GitHub Desktop isn't installed.
    ///
    /// - Throws: `.other` when GitHub Desktop couldn't be asked to open it.
    func forwardToGitHubDesktop(_ url: URL) async throws(OperationError) -> Bool {
        guard GitHubDesktopLinks.isLink(url) else {
            return false
        }
        if preferences.openGitHubDesktopLinks, case .openRepositoryFromURL = parseAppURL(url.absoluteString) {
            return false
        }
        let handlers = environment.urlSchemeHandlers
        guard let gitHubDesktop = handlers.applicationURL(bundleIdentifier: GitHubDesktopLinks.bundleIdentifier) else {
            return false
        }
        do {
            try await handlers.open(url, withApplicationAt: gitHubDesktop)
        } catch {
            logger.error("Couldn't pass a link on to GitHub Desktop: \(error.localizedDescription, privacy: .public)")
            throw OperationError(
                .other("Couldn't open the link in GitHub Desktop. \(error.localizedDescription)"),
                operation: .forwardLink,
                underlying: error
            )
        }
        logger.info("Passed a link on to GitHub Desktop")
        return true
    }
}
