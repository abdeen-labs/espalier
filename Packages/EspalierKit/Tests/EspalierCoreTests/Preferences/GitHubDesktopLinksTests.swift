// GitHub's "Open with GitHub Desktop" links.
// The setting gives both of their schemes to Espalier or back to GitHub
// Desktop, and is saved only once that's done. Only the switch changes it;
// while it's on, Espalier takes the links back from another app that has
// them. A link that reaches Espalier while it's off, or one Espalier can't
// open, goes to GitHub Desktop when it's installed. Launch Services is the
// harness's recording double, so nothing on this Mac changes.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("GitHub Desktop links", .offline, .hangGuard(minutes: 5)) @MainActor
struct GitHubDesktopLinksTests {
    private typealias DefaultHandler = RecordingURLSchemeHandlers.DefaultHandler
    private typealias OpenedLink = RecordingURLSchemeHandlers.OpenedLink

    /// An error from Launch Services.
    private var launchServicesError: NSError {
        NSError(domain: "LaunchServices", code: -54, userInfo: [NSLocalizedDescriptionKey: "Permission denied."])
    }

    private func link(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// Both schemes, given to the application at `applicationURL`.
    private func bothSchemes(_ applicationURL: URL) -> [DefaultHandler] {
        [
            DefaultHandler(scheme: "x-github-client", applicationURL: applicationURL),
            DefaultHandler(scheme: "github-mac", applicationURL: applicationURL),
        ]
    }

    /// The clone request `result` should be, for the URL it should name.
    private func cloneURL(_ result: ExternalActionResult) -> String? {
        guard case .cloneRequested(let request) = result else {
            Issue.record("Expected a clone request, got \(result)")
            return nil
        }
        return request.url
    }

    // MARK: The setting

    @Test("turning it on makes Espalier the default app for both schemes")
    func turnOn() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()

        try await app.integrations.setOpenGitHubDesktopLinks(true)
        #expect(handlers.defaultHandlers == bothSchemes(handlers.espalierURL))
        #expect(app.preferences.openGitHubDesktopLinks)
        #expect(app.integrations.opensGitHubDesktopLinks)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) as? Bool == true)
    }

    @Test("turning it off gives both schemes back to GitHub Desktop when it's installed")
    func turnOffWithGitHubDesktop() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        try await app.integrations.setOpenGitHubDesktopLinks(true)

        try await app.integrations.setOpenGitHubDesktopLinks(false)
        #expect(handlers.defaultHandlers == bothSchemes(handlers.espalierURL) + bothSchemes(handlers.gitHubDesktopURL))
        #expect(!app.preferences.openGitHubDesktopLinks)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) as? Bool == false)
    }

    @Test("turning it off asks for nothing when GitHub Desktop isn't installed")
    func turnOffWithoutGitHubDesktop() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        try await app.integrations.setOpenGitHubDesktopLinks(true)

        try await app.integrations.setOpenGitHubDesktopLinks(false)
        #expect(handlers.defaultHandlers == bothSchemes(handlers.espalierURL))
        #expect(!app.preferences.openGitHubDesktopLinks)
    }

    @Test("a change Launch Services refuses leaves the setting as it was and throws the error")
    func failure() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        handlers.setDefaultFailure = launchServicesError

        let onError = await #expect(throws: OperationError.self) {
            try await app.integrations.setOpenGitHubDesktopLinks(true)
        }
        #expect(onError?.operation == .setLinkHandler)
        #expect(onError?.reason == .other("Couldn't set Espalier to open GitHub Desktop links. Permission denied."))
        #expect(!app.preferences.openGitHubDesktopLinks)
        #expect(!app.integrations.opensGitHubDesktopLinks)
        #expect(app.integrations.pendingOpenGitHubDesktopLinks == nil)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) == nil)

        handlers.setDefaultFailure = nil
        try await app.integrations.setOpenGitHubDesktopLinks(true)
        handlers.setDefaultFailure = launchServicesError
        let offError = await #expect(throws: OperationError.self) {
            try await app.integrations.setOpenGitHubDesktopLinks(false)
        }
        #expect(offError?.reason == .other("Couldn't set GitHub Desktop to open its links again. Permission denied."))
        #expect(app.preferences.openGitHubDesktopLinks)
        #expect(app.integrations.opensGitHubDesktopLinks)
    }

    @Test("declining the change is a cancellation, and the setting stays as it was")
    func declined() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        harness.urlSchemeHandlers.setDefaultFailure = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        let error = await #expect(throws: OperationError.self) {
            try await app.integrations.setOpenGitHubDesktopLinks(true)
        }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(!app.preferences.openGitHubDesktopLinks)
    }

    @Test("the switch shows the value being applied, which is saved once it's applied; changes meanwhile are ignored")
    func pending() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.holdsChanges = true

        let integrations = app.integrations
        let turningOn = Task { try await integrations.setOpenGitHubDesktopLinks(true) }
        await handlers.waitUntilHeld()
        #expect(integrations.pendingOpenGitHubDesktopLinks == true)
        #expect(integrations.opensGitHubDesktopLinks)
        #expect(!app.preferences.openGitHubDesktopLinks)

        try await integrations.setOpenGitHubDesktopLinks(false)
        #expect(integrations.pendingOpenGitHubDesktopLinks == true)

        handlers.releaseHeldChanges()
        try await turningOn.value
        #expect(integrations.pendingOpenGitHubDesktopLinks == nil)
        #expect(app.preferences.openGitHubDesktopLinks)
        #expect(handlers.defaultHandlers == bothSchemes(handlers.espalierURL))
    }

    // MARK: Taking the links back

    /// Espalier, set for `scheme`.
    private func espalier(_ scheme: String, _ handlers: RecordingURLSchemeHandlers) -> DefaultHandler {
        DefaultHandler(scheme: scheme, applicationURL: handlers.espalierURL)
    }

    @Test("while the setting is on, Espalier takes back the links GitHub Desktop took as it becomes active, and the setting stays on")
    func takenBack() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        try await app.integrations.setOpenGitHubDesktopLinks(true)

        // Still Espalier's: nothing is asked.
        app.setActive(false)
        app.setActive(true)
        await app.integrations.gitHubDesktopLinksReclaimIdle()
        #expect(handlers.requestedHandlers == bothSchemes(handlers.espalierURL))

        app.setActive(false)
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        app.setActive(true)
        await app.integrations.gitHubDesktopLinksReclaimIdle()
        #expect(handlers.requestedHandlers == bothSchemes(handlers.espalierURL) + [espalier("x-github-client", handlers)])
        #expect(handlers.defaultApplications["x-github-client"] == handlers.espalierURL)
        #expect(app.preferences.openGitHubDesktopLinks)
        #expect(app.integrations.opensGitHubDesktopLinks)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) as? Bool == true)

        let opened = try await app.handle(.url(try link("x-github-client://openRepo/https://github.com/octocat/app")))
        #expect(cloneURL(opened) == "https://github.com/octocat/app")
        #expect(handlers.openedLinks.isEmpty)
        await app.idle()
    }

    @Test("each scheme another app, or none, opens is taken back, github-mac too")
    func eachScheme() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        let integrations = app.integrations
        let other = URL(filePath: "/Applications/Other.app", directoryHint: .isDirectory)
        try await integrations.setOpenGitHubDesktopLinks(true)

        handlers.defaultApplications["github-mac"] = other
        integrations.reclaimGitHubDesktopLinks()
        await integrations.gitHubDesktopLinksReclaimIdle()
        #expect(Array(handlers.requestedHandlers.dropFirst(2)) == [espalier("github-mac", handlers)])

        handlers.defaultApplications["x-github-client"] = nil
        handlers.defaultApplications["github-mac"] = other
        integrations.reclaimGitHubDesktopLinks()
        await integrations.gitHubDesktopLinksReclaimIdle()
        #expect(Array(handlers.requestedHandlers.dropFirst(3)) == bothSchemes(handlers.espalierURL))
        #expect(app.preferences.openGitHubDesktopLinks)
    }

    @Test("a setting saved on takes the links back from GitHub Desktop at launch")
    func atLaunch() async throws {
        let harness = try AppHarness()
        harness.defaults.defaults.set(true, forKey: PreferenceKey.openGitHubDesktopLinks)
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        handlers.defaultApplications["github-mac"] = handlers.gitHubDesktopURL

        let app = await harness.loadedApp()
        await app.idle()
        #expect(handlers.requestedHandlers == bothSchemes(handlers.espalierURL))
        #expect(app.preferences.openGitHubDesktopLinks)
    }

    @Test("with the setting off, nothing changes: links stay with the app that has them, and those that reach Espalier still go to GitHub Desktop")
    func offChangesNothing() async throws {
        let harness = try AppHarness()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        handlers.defaultApplications["github-mac"] = handlers.espalierURL
        let app = await harness.loadedApp()

        app.setActive(false)
        app.setActive(true)
        app.integrations.reclaimGitHubDesktopLinks()
        await app.idle()
        #expect(handlers.requestedHandlers.isEmpty)
        #expect(!app.preferences.openGitHubDesktopLinks)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) == nil)

        let url = try link("github-mac://openRepo/https://github.com/octocat/app")
        #expect(try await app.handle(.url(url)) == .forwarded)
        #expect(handlers.openedLinks == [OpenedLink(url: url, applicationURL: handlers.gitHubDesktopURL)])
    }

    @Test(
        "a re-claim Launch Services refuses, or the user declines, stops at that scheme, leaves the setting on, and isn't asked again until the next launch",
        arguments: [NamedCase("refused", false), NamedCase("declined", true)]
    )
    func reclaimFails(_ declined: NamedCase<Bool>) async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        try await app.integrations.setOpenGitHubDesktopLinks(true)
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        handlers.defaultApplications["github-mac"] = handlers.gitHubDesktopURL
        handlers.setDefaultFailure = declined.value
            ? NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            : launchServicesError

        app.setActive(false)
        app.setActive(true)
        await app.integrations.gitHubDesktopLinksReclaimIdle()
        let asked = bothSchemes(handlers.espalierURL) + [espalier("x-github-client", handlers)]
        #expect(handlers.requestedHandlers == asked)
        #expect(app.preferences.openGitHubDesktopLinks)
        #expect(app.integrations.opensGitHubDesktopLinks)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.openGitHubDesktopLinks) as? Bool == true)

        // Nothing is asked again, even once Launch Services would allow it.
        handlers.setDefaultFailure = nil
        app.setActive(false)
        app.setActive(true)
        app.integrations.reclaimGitHubDesktopLinks()
        await app.integrations.gitHubDesktopLinksReclaimIdle()
        #expect(handlers.requestedHandlers == asked)

        let relaunched = await harness.loadedApp()
        await relaunched.idle()
        #expect(handlers.requestedHandlers == asked + bothSchemes(handlers.espalierURL))
        #expect(relaunched.preferences.openGitHubDesktopLinks)
    }

    @Test("after a re-claim fails, the switch's next change lets re-claims run again")
    func reclaimAfterSwitchChange() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        let integrations = app.integrations
        handlers.installGitHubDesktop()
        try await integrations.setOpenGitHubDesktopLinks(true)
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        handlers.setDefaultFailure = launchServicesError
        integrations.reclaimGitHubDesktopLinks()
        await integrations.gitHubDesktopLinksReclaimIdle()
        handlers.setDefaultFailure = nil

        try await integrations.setOpenGitHubDesktopLinks(false)
        try await integrations.setOpenGitHubDesktopLinks(true)
        handlers.defaultApplications["github-mac"] = handlers.gitHubDesktopURL
        integrations.reclaimGitHubDesktopLinks()
        await integrations.gitHubDesktopLinksReclaimIdle()
        #expect(handlers.defaultHandlers.last == espalier("github-mac", handlers))
        #expect(handlers.defaultApplications["github-mac"] == handlers.espalierURL)
    }

    @Test("while the switch's change is being applied, no re-claim starts")
    func noReclaimWhilePending() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        let integrations = app.integrations
        try await integrations.setOpenGitHubDesktopLinks(true)

        // Turning it off, with GitHub Desktop given x-github-client links
        // before the change is done.
        handlers.holdsChanges = true
        let turningOff = Task { try await integrations.setOpenGitHubDesktopLinks(false) }
        await handlers.waitUntilHeld()
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        app.setActive(false)
        app.setActive(true)
        integrations.reclaimGitHubDesktopLinks()
        #expect(integrations.gitHubDesktopLinksReclaim == nil)

        handlers.releaseHeldChanges()
        try await turningOff.value
        #expect(!app.preferences.openGitHubDesktopLinks)
        #expect(handlers.requestedHandlers == bothSchemes(handlers.espalierURL) + bothSchemes(handlers.gitHubDesktopURL))
    }

    @Test("one re-claim runs at a time, and the switch's change waits for it, which stops before its next scheme")
    func switchWaitsForReclaim() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        let integrations = app.integrations
        try await integrations.setOpenGitHubDesktopLinks(true)
        handlers.defaultApplications["x-github-client"] = handlers.gitHubDesktopURL
        handlers.defaultApplications["github-mac"] = handlers.gitHubDesktopURL

        handlers.holdsChanges = true
        integrations.reclaimGitHubDesktopLinks()
        await handlers.waitUntilHeld()
        app.setActive(false)
        app.setActive(true)
        let turningOff = Task { try await integrations.setOpenGitHubDesktopLinks(false) }
        await waitUntilObserved { integrations.pendingOpenGitHubDesktopLinks == false }
        handlers.releaseHeldChanges()
        try await turningOff.value

        #expect(handlers.requestedHandlers == bothSchemes(handlers.espalierURL)
            + [espalier("x-github-client", handlers)]
            + bothSchemes(handlers.gitHubDesktopURL))
        #expect(handlers.defaultApplications == ["x-github-client": handlers.gitHubDesktopURL, "github-mac": handlers.gitHubDesktopURL])
        #expect(!app.preferences.openGitHubDesktopLinks)
        #expect(integrations.gitHubDesktopLinksReclaim == nil)
    }

    @Test("Launch Services' Espalier is this copy, or another with its bundle identifier")
    func espalierCopies() throws {
        let directory = try createTempDirectory()
        func application(_ name: String, bundleIdentifier: String) throws -> URL {
            let url = URL(filePath: POSIXPath.join(directory, name, "Contents"), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appending(path: "Info.plist", directoryHint: .notDirectory))
            return URL(filePath: POSIXPath.join(directory, name), directoryHint: .isDirectory)
        }
        let espalier = try application("Espalier.app", bundleIdentifier: "com.example.espalier-tests")
        let otherCopy = try application("Espalier Copy.app", bundleIdentifier: "com.example.espalier-tests")
        let gitHubDesktop = try application("GitHub Desktop.app", bundleIdentifier: GitHubDesktopLinks.bundleIdentifier)
        let handlers = LaunchServicesURLSchemeHandlers(bundle: try #require(Bundle(url: espalier)))

        #expect(handlers.isEspalier(espalier))
        #expect(handlers.isEspalier(URL(filePath: POSIXPath.join(directory, "Espalier.app"), directoryHint: .notDirectory)))
        #expect(handlers.isEspalier(otherCopy))
        #expect(!handlers.isEspalier(gitHubDesktop))
        #expect(!handlers.isEspalier(URL(filePath: POSIXPath.join(directory, "Missing.app"), directoryHint: .isDirectory)))
    }

    // MARK: Links that reach Espalier

    @Test("with the setting off and GitHub Desktop installed, its links go to GitHub Desktop, without waiting for the repository list")
    func forwardedWhenOff() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let handlers = harness.urlSchemeHandlers
        handlers.installGitHubDesktop()
        let current = try link("x-github-client://openRepo/https://github.com/octocat/app?branch=feature")
        let older = try link("GitHub-Mac://openRepo/https://github.com/octocat/app")

        #expect(try await app.handle(.url(current)) == .forwarded)
        #expect(try await app.handle(.url(older)) == .forwarded)
        #expect(handlers.openedLinks == [
            OpenedLink(url: current, applicationURL: handlers.gitHubDesktopURL),
            OpenedLink(url: older, applicationURL: handlers.gitHubDesktopURL),
        ])
        #expect(app.loadState == .notLoaded)
        #expect(app.selection == nil)
        #expect(harness.workspace.revealedPaths.isEmpty)
    }

    @Test("with the setting off and GitHub Desktop missing, Espalier opens its links")
    func handledWhenGitHubDesktopIsMissing() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        let current = try await app.handle(.url(try link("x-github-client://openRepo/https://github.com/octocat/app")))
        #expect(cloneURL(current) == "https://github.com/octocat/app")
        let older = try await app.handle(.url(try link("github-mac://openRepo/https://github.com/octocat/other")))
        #expect(cloneURL(older) == "https://github.com/octocat/other")
        #expect(harness.urlSchemeHandlers.openedLinks.isEmpty)
        await app.idle()
    }

    @Test("with the setting on, Espalier opens GitHub Desktop's links")
    func handledWhenOn() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        harness.urlSchemeHandlers.installGitHubDesktop()
        try await app.integrations.setOpenGitHubDesktopLinks(true)

        let current = try await app.handle(.url(try link("x-github-client://openRepo/https://github.com/octocat/app")))
        #expect(cloneURL(current) == "https://github.com/octocat/app")
        let older = try await app.handle(.url(try link("github-mac://openRepo/https://github.com/octocat/other")))
        #expect(cloneURL(older) == "https://github.com/octocat/other")
        #expect(harness.urlSchemeHandlers.openedLinks.isEmpty)
        await app.idle()
    }

    @Test("with the setting on, a link Espalier can't open goes to GitHub Desktop when it's installed, and is ignored when it isn't")
    func otherActionsWhenOn() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let handlers = harness.urlSchemeHandlers
        try await app.integrations.setOpenGitHubDesktopLinks(true)
        let signIn = try link("x-github-client://oauth?code=abc&state=xyz")

        #expect(try await app.handle(.url(signIn)) == .ignored("Espalier can't open this link: x-github-client://oauth?code=abc&state=xyz"))
        #expect(handlers.openedLinks.isEmpty)

        handlers.installGitHubDesktop()
        let older = try link("github-mac://oauth?code=abc&state=xyz")
        // An openRepo link Espalier rejects: its pull request isn't a number.
        let malformed = try link("x-github-client://openRepo/https://github.com/octocat/app?pr=abc")
        for url in [signIn, older, malformed] {
            #expect(try await app.handle(.url(url)) == .forwarded)
        }
        #expect(handlers.openedLinks == [signIn, older, malformed].map { OpenedLink(url: $0, applicationURL: handlers.gitHubDesktopURL) })

        // Its openRepo links stay Espalier's, and espalier:// links never go
        // to GitHub Desktop.
        let opened = try await app.handle(.url(try link("x-github-client://openRepo/https://github.com/octocat/app")))
        #expect(cloneURL(opened) == "https://github.com/octocat/app")
        let own = try await app.handle(.url(try link("espalier://oauth?code=abc&state=xyz")))
        #expect(own == .ignored("Espalier can't open this link: espalier://oauth?code=abc&state=xyz"))
        #expect(handlers.openedLinks.count == 3)
        await app.idle()
    }

    @Test("espalier:// links are always Espalier's")
    func espalierLinks() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        harness.urlSchemeHandlers.installGitHubDesktop()

        let result = try await app.handle(.url(try link("espalier://openRepo/https://github.com/octocat/app")))
        #expect(cloneURL(result) == "https://github.com/octocat/app")
        #expect(harness.urlSchemeHandlers.openedLinks.isEmpty)
        await app.idle()
    }

    @Test("a link GitHub Desktop can't be asked to open throws the error, and Espalier doesn't open it")
    func forwardingFails() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        harness.urlSchemeHandlers.installGitHubDesktop()
        harness.urlSchemeHandlers.openFailure = launchServicesError

        let url = try link("x-github-client://openRepo/https://github.com/octocat/app")
        let error = await #expect(throws: OperationError.self) {
            _ = try await app.handle(.url(url))
        }
        #expect(error?.operation == .forwardLink)
        #expect(error?.reason == .other("Couldn't open the link in GitHub Desktop. Permission denied."))
        #expect(app.loadState == .notLoaded)
        #expect(app.selection == nil)
    }
}
