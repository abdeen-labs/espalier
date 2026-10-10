// The window's image loader. Which requests carry a token (an Enterprise
// server's avatars API and repository assets, on the account's own origin,
// GitHub.com's API token for github.com too), tokens dropped on redirects
// to another origin, images loaded once and cached, failures not tried
// again for 5 minutes but at once when the network comes back, avatars
// handed to the window's avatar loader, and the tokens following the
// signed-in accounts. Requests go to a mock server.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import Observation
import GitHubKit
import Testing
import TestSupport
@testable import EspalierUI

/// A small PNG.
private let pngData: Data = {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}()

/// How many times the loader applied the accounts, observably.
@MainActor @Observable
private final class Passes {
    var count = 0
}

@Suite("Authenticated image loader", .offline, .hangGuard(minutes: 5)) @MainActor
struct AuthenticatedImageLoaderTests {
    private let enterpriseEndpoint = "https://ghe.example.com/api/v3"

    private var tokens: [String: String] {
        ImageAuthorization.tokens(for: [
            Account(login: "octocat", endpoint: getDotComAPIEndpoint(), token: "gho_dotcom", emails: [], avatarURL: "", id: 1, name: ""),
            Account(login: "jbloggs", endpoint: enterpriseEndpoint, token: "gho_enterprise", emails: [], avatarURL: "", id: 2, name: ""),
            Account(login: "signedout", endpoint: "https://other.example.com/api/v3", token: "", emails: [], avatarURL: "", id: 3, name: ""),
        ])
    }

    /// A window's loader on `server`, with its own avatars.
    private func loader(_ server: MockGitHub, clock: TestClock = TestClock(), network: NetworkReturnMonitor? = nil) -> AuthenticatedImageLoader {
        let avatars = GitHubAvatarLoader(
            session: server.session,
            runtime: server.runtime,
            now: { clock.now() },
            supportsAvatarsAPI: { _ in true },
            network: network,
            images: RetainingImageCache()
        )
        return AuthenticatedImageLoader(session: server.session, avatars: avatars, now: { clock.now() }, network: network, images: RetainingImageCache())
    }

    @Test("tokens by origin: each account's server, and github.com with GitHub.com's API token")
    func originTokens() {
        #expect(tokens == [
            "https://api.github.com": "gho_dotcom",
            "https://github.com": "gho_dotcom",
            "https://ghe.example.com": "gho_enterprise",
        ])
    }

    @Test("a token goes with an Enterprise avatar or a repository asset on its own origin, nothing else")
    func authorization() {
        func header(_ string: String) -> String? {
            ImageAuthorization.header(for: URL(string: string)!, tokens: tokens)
        }
        #expect(header("https://ghe.example.com/api/v3/enterprise/avatars/u/e?email=a%40b.c&s=32") == "token gho_enterprise")
        #expect(header("https://github.com/user-attachments/assets/0f2c6c1e-4b1a") == "token gho_dotcom")
        #expect(header("https://github.com/octocat/hello/assets/1/2f3a") == "token gho_dotcom")
        #expect(header("https://ghe.example.com/octocat/hello/assets/9/abc/") == "token gho_enterprise")
        #expect(header("https://github.com/octocat/hello/blob/main/shot.png") == nil)
        #expect(header("https://github.com/user-attachments/files/123/log.txt") == nil)
        #expect(header("https://evil.example.com/user-attachments/assets/0f2c") == nil)
        #expect(header("https://private-user-images.githubusercontent.com/1/2.png?jwt=x") == nil)
        #expect(header("http://github.com/user-attachments/assets/0f2c") == nil)
        #expect(header("https://avatars.githubusercontent.com/u/e?email=a%40b.c&s=32") == nil)
    }

    @Test("a redirect to another origin drops the token; one on the same origin keeps it")
    func redirects() async throws {
        var original = URLRequest(url: URL(string: "https://github.com/user-attachments/assets/0f2c")!)
        original.setValue("token gho_dotcom", forHTTPHeaderField: "Authorization")
        var sameOrigin = URLRequest(url: URL(string: "https://github.com/user-attachments/assets/0f2c?download=1")!)
        sameOrigin.setValue("token gho_dotcom", forHTTPHeaderField: "Authorization")
        var otherOrigin = URLRequest(url: URL(string: "https://private-user-images.githubusercontent.com/1.png?jwt=x")!)
        otherOrigin.setValue("token gho_dotcom", forHTTPHeaderField: "Authorization")
        #expect(SameOriginAuthorization.redirect(sameOrigin, from: original).value(forHTTPHeaderField: "Authorization") == "token gho_dotcom")
        #expect(SameOriginAuthorization.redirect(otherOrigin, from: original).value(forHTTPHeaderField: "Authorization") == nil)
        #expect(SameOriginAuthorization.redirect(sameOrigin, from: nil).value(forHTTPHeaderField: "Authorization") == nil)

        // Through a session: GitHub's private assets redirect to signed URLs.
        let server = MockGitHub()
        server.on("GET", "/user-attachments/assets/0f2c", respond: .redirect(to: URL(string: "https://private-user-images.githubusercontent.com/1.png?jwt=x")!, status: 302))
        server.on("GET", "/1.png", respond: .http(status: 200, headers: ["Content-Type": "image/png"], body: pngData))
        let images = loader(server)
        images.setAccounts([GitHubFixtures.dotComAccount])
        #expect(await images.image(at: URL(string: "https://github.com/user-attachments/assets/0f2c")!, maximumPixels: 100) != nil)
        #expect(server.requests("GET", "/user-attachments/assets/0f2c").first?.header("Authorization") == "token gho_octocat")
        let signed = try #require(server.requests("GET", "/1.png").first)
        #expect(signed.url.host == "private-user-images.githubusercontent.com")
        #expect(signed.header("Authorization") == nil)
        withExtendedLifetime(server) {}
    }

    @Test("an image loads once with the token, then from the cache; a failure isn't tried again for 5 minutes, or until the network comes back")
    func loading() async throws {
        let server = MockGitHub()
        server.on("GET", "/user-attachments/assets/0f2c", respond: .http(status: 200, headers: ["Content-Type": "image/png"], body: pngData))
        server.on("GET", "/user-attachments/assets/missing", respond: .status(404))
        let clock = TestClock()
        let network = NetworkReturnMonitor(watchesPath: false)
        let images = loader(server, clock: clock, network: network)
        images.setAccounts([GitHubFixtures.dotComAccount])

        let url = URL(string: "https://github.com/user-attachments/assets/0f2c")!
        #expect(images.cachedImage(at: url, maximumPixels: 100) == nil)
        let image = try #require(await images.image(at: url, maximumPixels: 100))
        #expect(image.width == 4)
        #expect(images.cachedImage(at: url, maximumPixels: 100) != nil)
        _ = await images.image(at: url, maximumPixels: 100)
        let requests = server.requests("GET", "/user-attachments/assets/0f2c")
        #expect(requests.count == 1)
        #expect(requests.first?.header("Authorization") == "token gho_octocat")

        let missing = URL(string: "https://github.com/user-attachments/assets/missing")!
        #expect(await images.image(at: missing, maximumPixels: 100) == nil)
        clock.advance(by: 4 * 60)
        #expect(await images.image(at: missing, maximumPixels: 100) == nil)
        #expect(server.requests("GET", "/user-attachments/assets/missing").count == 1)
        clock.advance(by: 60)
        #expect(await images.image(at: missing, maximumPixels: 100) == nil)
        #expect(server.requests("GET", "/user-attachments/assets/missing").count == 2)
        // The network comes back: tried again at once.
        network.pathChanged(satisfied: false)
        network.pathChanged(satisfied: true)
        #expect(await images.image(at: missing, maximumPixels: 100) == nil)
        #expect(server.requests("GET", "/user-attachments/assets/missing").count == 3)

        // Signed out: images loaded with the token are forgotten, and the
        // next request carries none.
        images.setAccounts([])
        #expect(images.cachedImage(at: url, maximumPixels: 100) == nil)
        _ = await images.image(at: url, maximumPixels: 100)
        #expect(server.requests("GET", "/user-attachments/assets/0f2c").last?.header("Authorization") == nil)
        withExtendedLifetime(server) {}
    }

    @Test("avatars come from the window's avatar loader, which gets the accounts too")
    func avatars() async throws {
        let server = MockGitHub()
        server.on("GET", "/api/v3/enterprise/avatars/u/e", respond: .http(status: 200, headers: ["Content-Type": "image/png"], body: pngData))
        let images = loader(server)
        images.setAccounts([GitHubFixtures.enterpriseAccount])
        let joe = AvatarUser(email: "joe@corp.example.com", avatarURL: nil, name: "Joe", endpoint: enterpriseEndpoint)

        #expect(await images.image(for: joe, pointSize: 16, scale: 2) != nil)
        let request = try #require(server.requests("GET", "/api/v3/enterprise/avatars/u/e").first)
        #expect(request.query == ["email": "joe@corp.example.com", "s": "32"])
        #expect(request.header("Authorization") == "token gho_enterprise")
        #expect(images.cachedImage(for: joe, pointSize: 16, scale: 2) != nil)
        withExtendedLifetime(server) {}
    }

    @Test("the window's loader follows the signed-in accounts, for images and avatars")
    @MainActor
    func followsAccounts() async throws {
        let harness = try AppHarness()
        try await harness.environment.accountsStore.addAccount(GitHubFixtures.enterpriseAccount)
        let app = await harness.loadedApp()
        await app.accounts.idle()
        let gitHub = harness.gitHub
        let images = loader(gitHub)
        images.follow(app.accounts)
        gitHub.on("GET", "/api/v3/enterprise/avatars/u/e", respond: .status(404))
        let avatarURL = URL(string: "https://ghe.example.com/api/v3/enterprise/avatars/u/e")!
        _ = await images.image(at: avatarURL, maximumPixels: 32)
        #expect(gitHub.requests("GET", "/api/v3/enterprise/avatars/u/e").last?.header("Authorization") == "token gho_enterprise")
        let joe = AvatarUser(email: "joe@corp.example.com", avatarURL: nil, name: "Joe", endpoint: enterpriseEndpoint)
        _ = await images.image(for: joe, pointSize: 16, scale: 2)
        #expect(gitHub.requests("GET", "/api/v3/enterprise/avatars/u/e").last?.header("Authorization") == "token gho_enterprise")

        // The observation hands the change over in a task: wait for the
        // loader's pass over the accounts that drops the token.
        let passes = Passes()
        images.accountsFollowed = { passes.count += 1 }
        try await app.accounts.signOut(GitHubFixtures.enterpriseAccount)
        await waitUntil { passes.count > 0 && images.tokenCount == 0 }
        #expect(app.accounts.accounts.isEmpty)
        let fresh = URL(string: "https://ghe.example.com/api/v3/enterprise/avatars/u/e?again=1")!
        _ = await images.image(at: fresh, maximumPixels: 32)
        #expect(gitHub.requests("GET", "/api/v3/enterprise/avatars/u/e").last?.header("Authorization") == nil)
        // The avatar's failure was forgotten with the accounts: asked again,
        // without a token.
        _ = await images.image(for: joe, pointSize: 16, scale: 2)
        #expect(gitHub.requests("GET", "/api/v3/enterprise/avatars/u/e").count == 4)
        #expect(gitHub.requests("GET", "/api/v3/enterprise/avatars/u/e").last?.header("Authorization") == nil)
        await app.accounts.idle()
        withExtendedLifetime(harness) {}
    }
}
