// Which URLs an avatar tries on each kind of host, a repository with no
// host loading GitHub.com's; an Enterprise Server's avatars API with the
// token of an account signed in there, or none, never to another origin;
// ghe.com noreply logins and bots looked up through the API, kept (ghe.com's
// for 50 minutes); known bots without asking; GitHub's stand-in for an
// unknown email as no avatar, remembered; a failure not tried again for 5
// minutes, but at once when the network comes back or an account signs in.
// Images come from a mock server, the API from a mock GitHub, time from a
// test clock.

import AppKit
import CryptoKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import Synchronization
import Testing
import TestSupport
@testable import EspalierUI

/// A small PNG.
private let avatarPNG: Data = {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}()

/// A PNG answer.
private let image = MockGitHub.Response.http(status: 200, headers: ["Content-Type": "image/png"], body: avatarPNG)

/// GitHub's stand-in for an email it doesn't know, by its ETag.
private let standIn = MockGitHub.Response.http(
    status: 200,
    headers: ["Content-Type": "image/png", "ETag": "\"\(GitHubAvatarStandIn.digest)\""],
    body: avatarPNG
)

private let dotCom = getDotComAPIEndpoint()
private let enterprise = "https://ghe.example.com/api/v3"
private let tenant = "https://api.tenant.ghe.com"

/// A ghe.com account.
private let tenantAccount = Account(
    login: "mona",
    endpoint: tenant,
    token: "gho_tenant",
    emails: [],
    avatarURL: "",
    id: 9,
    name: "Mona",
    clientID: "Ov23liTenantApp01"
)

/// A user as the API's lookup returns it.
private func apiUser(_ login: String, avatarURL: String) -> APIFullIdentity {
    APIFullIdentity(id: 7, htmlURL: "https://github.com/\(login)", login: login, avatarURL: avatarURL, name: nil, email: nil, type: GitHubAccountType(rawValue: "Bot"), plan: nil)
}

@Suite("Avatar loader", .offline) @MainActor
struct AvatarLoaderTests {
    private func loader(
        _ server: MockGitHub,
        clock: TestClock = TestClock(),
        supportsAvatarsAPI: Bool = true,
        network: NetworkReturnMonitor? = nil
    ) -> GitHubAvatarLoader {
        GitHubAvatarLoader(
            session: server.session,
            runtime: server.runtime,
            now: { clock.now() },
            supportsAvatarsAPI: { _ in supportsAvatarsAPI },
            network: network,
            images: RetainingImageCache()
        )
    }

    private func user(_ email: String, avatarURL: String? = nil, endpoint: String?) -> AvatarUser {
        AvatarUser(email: email, avatarURL: avatarURL, name: "Joe Bloggs", endpoint: endpoint)
    }

    // MARK: Where avatars come from

    @Test("each kind of host's URLs, in desktop's order; no host means GitHub.com")
    func candidates() {
        func urls(_ user: AvatarUser, supportsAvatarsAPI: Bool = true) -> [String] {
            avatarURLCandidates(for: user, size: 32, supportsAvatarsAPI: supportsAvatarsAPI).map(\.absoluteString)
        }
        // GitHub.com, and no host.
        #expect(urls(user("joe@example.com", endpoint: nil)) == ["https://avatars.githubusercontent.com/u/e?email=joe%40example.com&s=32"])
        #expect(urls(user("joe+git@example.com", endpoint: dotCom)) == ["https://avatars.githubusercontent.com/u/e?email=joe%2Bgit%40example.com&s=32"])
        #expect(urls(user("123+joe@users.noreply.github.com", endpoint: nil)) == ["https://avatars.githubusercontent.com/u/123?s=32"])
        // A noreply address without a user ID goes by email.
        #expect(urls(user("joe@users.noreply.github.com", endpoint: dotCom)) == ["https://avatars.githubusercontent.com/u/e?email=joe%40users.noreply.github.com&s=32"])
        #expect(urls(user("joe@example.com", avatarURL: "https://avatars.githubusercontent.com/u/1?v=4&s=460", endpoint: dotCom)) == [
            "https://avatars.githubusercontent.com/u/1?v=4&s=32",
            "https://avatars.githubusercontent.com/u/e?email=joe%40example.com&s=32",
        ])
        #expect(urls(user("", avatarURL: "https://avatars.githubusercontent.com/u/1?v=4", endpoint: dotCom)) == ["https://avatars.githubusercontent.com/u/1?v=4&s=32"])

        // An Enterprise Server: its avatars API by email, never the API's
        // URL (behind private mode); nothing before 3.0.
        #expect(urls(user("joe@corp.example.com", avatarURL: "https://ghe.example.com/avatars/u/2", endpoint: enterprise))
            == ["https://ghe.example.com/api/v3/enterprise/avatars/u/e?email=joe%40corp.example.com&s=32"])
        #expect(urls(user("joe@corp.example.com", endpoint: "https://ghe.example.com/api/v3/")).first
            == "https://ghe.example.com/api/v3/enterprise/avatars/u/e?email=joe%40corp.example.com&s=32")
        #expect(urls(user("joe@corp.example.com", endpoint: enterprise), supportsAvatarsAPI: false).isEmpty)

        // ghe.com: the API's URL only (its email form needs a token this app
        // can't get).
        #expect(urls(user("joe@tenant.example", avatarURL: "https://avatars.tenant.ghe.com/u/2?v=4", endpoint: tenant))
            == ["https://avatars.tenant.ghe.com/u/2?v=4&s=32"])
        #expect(urls(user("joe@tenant.example", endpoint: tenant)).isEmpty)
    }

    @Test("which logins the API looks up: bots' noreply logins, and every noreply login on ghe.com")
    func lookupLogins() {
        #expect(avatarLookupLogin(for: user("1234+renovate[bot]@users.noreply.github.com", endpoint: dotCom)) == "renovate[bot]")
        #expect(avatarLookupLogin(for: user("renovate[bot]@users.noreply.github.com", endpoint: dotCom)) == "renovate[bot]")
        #expect(avatarLookupLogin(for: user("1234+joe@users.noreply.github.com", endpoint: dotCom)) == nil)
        #expect(avatarLookupLogin(for: user("1234+joe@users.noreply.github.com", endpoint: tenant)) == "joe")
        #expect(avatarLookupLogin(for: user("joe@example.com", endpoint: tenant)) == nil)
        // A known avatar URL, or no GitHub host: nothing to look up.
        #expect(avatarLookupLogin(for: user("1234+renovate[bot]@users.noreply.github.com", avatarURL: "https://x.example/1", endpoint: dotCom)) == nil)
        #expect(avatarLookupLogin(for: user("1234+renovate[bot]@users.noreply.github.com", endpoint: nil)) == nil)
    }

    /// The avatar of the author of a pull request on `endpoint`'s server.
    private func pullRequestAuthor(endpoint: String, avatarURL: String?) -> AvatarUser {
        let repository = GitHubRepository(
            name: "hello",
            owner: Owner(login: "octocat", endpoint: endpoint, id: 1),
            dbID: 1,
            htmlURL: "https://example.com/octocat/hello",
            cloneURL: "https://example.com/octocat/hello.git"
        )
        let ref = PullRequestRef(ref: "main", sha: String(repeating: "a", count: 40), gitHubRepository: repository)
        let pullRequest = PullRequest(
            created: Date(timeIntervalSince1970: 0),
            title: "Add the sign-in sheet",
            pullRequestNumber: 1,
            head: ref,
            base: ref,
            author: "octo",
            authorAvatarURL: avatarURL,
            draft: false,
            body: ""
        )
        return PullRequestOverviewContent(pullRequest, isCurrentBranch: false).authorAvatar
    }

    @Test("a pull request's author: the API's avatar URL first, then the login's noreply address; an Enterprise Server's by its avatars API")
    func pullRequestAuthorCandidates() {
        func urls(_ user: AvatarUser) -> [String] {
            avatarURLCandidates(for: user, size: 32, supportsAvatarsAPI: true).map(\.absoluteString)
        }
        #expect(urls(pullRequestAuthor(endpoint: dotCom, avatarURL: "https://avatars.githubusercontent.com/u/7?v=4")) == [
            "https://avatars.githubusercontent.com/u/7?v=4&s=32",
            "https://avatars.githubusercontent.com/u/e?email=octo%40users.noreply.github.com&s=32",
        ])
        // Cached before avatar URLs were kept: the noreply address alone.
        #expect(urls(pullRequestAuthor(endpoint: dotCom, avatarURL: nil))
            == ["https://avatars.githubusercontent.com/u/e?email=octo%40users.noreply.github.com&s=32"])
        // An Enterprise Server's avatar URL is behind private mode.
        #expect(urls(pullRequestAuthor(endpoint: enterprise, avatarURL: "https://ghe.example.com/avatars/u/7"))
            == ["https://ghe.example.com/api/v3/enterprise/avatars/u/e?email=octo%40users.noreply.ghe.example.com&s=32"])
        // ghe.com: the API's URL, with nothing to look up; without it, the
        // login is looked up.
        let tenantAuthor = pullRequestAuthor(endpoint: tenant, avatarURL: "https://avatars.tenant.ghe.com/u/7?v=4")
        #expect(urls(tenantAuthor) == ["https://avatars.tenant.ghe.com/u/7?v=4&s=32"])
        #expect(avatarLookupLogin(for: tenantAuthor) == nil)
        #expect(avatarLookupLogin(for: pullRequestAuthor(endpoint: tenant, avatarURL: nil)) == "octo")
    }

    @Test("a ghe.com pull request author's avatar loads from the API's URL without a user lookup")
    func pullRequestAuthorOnTenant() async throws {
        let server = MockGitHub()
        server.on("GET", "/u/7", respond: image)
        let avatars = loader(server)
        avatars.setAccounts([tenantAccount])
        let author = pullRequestAuthor(endpoint: tenant, avatarURL: "https://avatars.tenant.ghe.com/u/7?v=4")

        #expect(await avatars.image(for: author, pointSize: 16, scale: 2) != nil)
        let request = try #require(server.requests("GET", "/u/7").first)
        #expect(request.url.host == "avatars.tenant.ghe.com")
        #expect(request.header("Authorization") == nil)
        #expect(server.requests("GET", "/users/octo").isEmpty)
        withExtendedLifetime(server) {}
    }

    // MARK: Enterprise Server

    @Test("an Enterprise Server's avatars API: with the token of an account signed in there, without one otherwise")
    func enterpriseServer() async throws {
        let server = MockGitHub()
        server.on("GET", "/api/v3/enterprise/avatars/u/e", respond: image)
        let avatars = loader(server)
        let joe = user("joe@corp.example.com", endpoint: enterprise)

        // No account there: asked anyway, without a token.
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        let first = try #require(server.requests("GET", "/api/v3/enterprise/avatars/u/e").first)
        #expect(first.url.host == "ghe.example.com")
        #expect(first.query == ["email": "joe@corp.example.com", "s": "32"])
        #expect(first.header("Authorization") == nil)
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) != nil)

        // Signed in there (images loaded without a token are forgotten):
        // its token. GitHub.com's account's token never goes there.
        avatars.setAccounts([GitHubFixtures.dotComAccount, GitHubFixtures.enterpriseAccount])
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) == nil)
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/api/v3/enterprise/avatars/u/e").last?.header("Authorization") == "token gho_enterprise")

        // Another server: no token, even with accounts signed in.
        let other = user("joe@corp.example.com", endpoint: "https://other.example.com/api/v3")
        #expect(await avatars.image(for: other, pointSize: 16, scale: 2) != nil)
        let request = try #require(server.requests.last)
        #expect(request.url.host == "other.example.com")
        #expect(request.header("Authorization") == nil)
        withExtendedLifetime(server) {}
    }

    @Test("a token never follows a redirect to another origin")
    func redirectedToken() async throws {
        let server = MockGitHub()
        server.on("GET", "/api/v3/enterprise/avatars/u/e", respond: .redirect(to: URL(string: "https://media.example.net/avatars/2")!, status: 302))
        server.on("GET", "/avatars/2", respond: image)
        let avatars = loader(server)
        avatars.setAccounts([GitHubFixtures.enterpriseAccount])

        #expect(await avatars.image(for: user("joe@corp.example.com", endpoint: enterprise), pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/api/v3/enterprise/avatars/u/e").first?.header("Authorization") == "token gho_enterprise")
        let redirected = try #require(server.requests("GET", "/avatars/2").first)
        #expect(redirected.url.host == "media.example.net")
        #expect(redirected.header("Authorization") == nil)
        withExtendedLifetime(server) {}
    }

    // MARK: ghe.com and bots

    @Test("a ghe.com noreply login's avatar comes from the API's user lookup, kept for 50 minutes")
    func gheLogin() async throws {
        let server = MockGitHub()
        server.on("GET", "/users/joe", respond: .json(encoding: apiUser("joe", avatarURL: "https://avatars.tenant.ghe.com/u/12?v=4")))
        server.on("GET", "/u/12", respond: image)
        let clock = TestClock()
        let avatars = loader(server, clock: clock)
        let joe = user("12+joe@users.noreply.github.com", endpoint: tenant)

        // No account for the tenant: a monogram, and no request.
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) == nil)
        #expect(server.requests.isEmpty)

        avatars.setAccounts([tenantAccount])
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        let lookup = try #require(server.requests("GET", "/users/joe").first)
        #expect(lookup.url.host == "api.tenant.ghe.com")
        #expect(lookup.header("Authorization") == "Bearer gho_tenant")
        let avatar = try #require(server.requests("GET", "/u/12").first)
        #expect(avatar.url.host == "avatars.tenant.ghe.com")
        #expect(avatar.query == ["v": "4", "s": "32"])
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) != nil)

        // Another size within 50 minutes: no new lookup.
        clock.advance(by: 49 * 60)
        #expect(await avatars.image(for: joe, pointSize: 24, scale: 2) != nil)
        #expect(server.requests("GET", "/users/joe").count == 1)
        // After 50 minutes, looked up again; what's loaded still shows.
        clock.advance(by: 2 * 60)
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(await avatars.image(for: joe, pointSize: 32, scale: 2) != nil)
        #expect(server.requests("GET", "/users/joe").count == 2)
        withExtendedLifetime(server) {}
    }

    @Test("known bots show their apps' avatars without asking; other bots are looked up once, with an account")
    func bots() async throws {
        let server = MockGitHub()
        server.on("GET", "/in/29110", respond: image)
        server.on("GET", "/users/renovate%5Bbot%5D", respond: .json(encoding: apiUser("renovate[bot]", avatarURL: "https://avatars.githubusercontent.com/in/2740?v=4")))
        server.on("GET", "/in/2740", respond: image)
        server.on("GET", "/u/29139614", respond: image)
        let avatars = loader(server)
        avatars.setAccounts([GitHubFixtures.dotComAccount])

        // Dependabot, by either address, and in a repository with no host.
        for email in ["49699333+dependabot[bot]@users.noreply.github.com", "dependabot[bot]@users.noreply.github.com"] {
            #expect(await avatars.image(for: user(email, endpoint: dotCom), pointSize: 16, scale: 2) != nil)
        }
        #expect(await avatars.image(for: user("dependabot[bot]@users.noreply.github.com", endpoint: nil), pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/in/29110").count == 1)
        #expect(server.requests("GET", "/in/29110").first?.query == ["v": "4", "s": "32"])

        // Renovate: looked up, then kept.
        let renovate = user("29139614+renovate[bot]@users.noreply.github.com", endpoint: dotCom)
        #expect(await avatars.image(for: renovate, pointSize: 16, scale: 2) != nil)
        #expect(await avatars.image(for: renovate, pointSize: 24, scale: 2) != nil)
        #expect(server.requests("GET", "/users/renovate%5Bbot%5D").count == 1)
        #expect(server.requests("GET", "/in/2740").count == 2)

        // Without an account: by its user ID.
        avatars.setAccounts([])
        let another = user("29139614+renovate[bot]@users.noreply.github.com", endpoint: "https://api.github.com/")
        #expect(await avatars.image(for: another, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/u/29139614").count == 1)
        #expect(server.requests("GET", "/users/renovate%5Bbot%5D").count == 1)
        withExtendedLifetime(server) {}
    }

    @Test("a lookup that fails isn't tried again for 5 minutes; the email form is tried meanwhile")
    func failedLookup() async throws {
        let server = MockGitHub()
        server.on("GET", "/users/renovate%5Bbot%5D", respond: .json(["message": "Not Found"], status: 404))
        server.on("GET", "/u/29139614", respond: image)
        let clock = TestClock()
        let avatars = loader(server, clock: clock)
        avatars.setAccounts([GitHubFixtures.dotComAccount])
        let renovate = user("29139614+renovate[bot]@users.noreply.github.com", endpoint: dotCom)

        #expect(await avatars.image(for: renovate, pointSize: 16, scale: 2) != nil)
        #expect(await avatars.image(for: renovate, pointSize: 24, scale: 2) != nil)
        #expect(server.requests("GET", "/users/renovate%5Bbot%5D").count == 1)
        clock.advance(by: 5 * 60)
        _ = await avatars.image(for: renovate, pointSize: 32, scale: 2)
        #expect(server.requests("GET", "/users/renovate%5Bbot%5D").count == 2)
        withExtendedLifetime(server) {}
    }

    // MARK: GitHub's stand-in

    @Test("GitHub's stand-in for an unknown email is no avatar, and isn't asked for again")
    func standInAnswer() async throws {
        let server = MockGitHub()
        server.on("GET", "/u/e", respond: standIn)
        let clock = TestClock()
        let avatars = loader(server, clock: clock)
        let unknown = user("nobody@example.com", endpoint: nil)

        #expect(await avatars.image(for: unknown, pointSize: 16, scale: 2) == nil)
        #expect(avatars.cachedImage(for: unknown, pointSize: 16, scale: 2) == nil)
        // Not a failure: an hour later, and after the network comes back,
        // still no second request.
        clock.advance(by: 60 * 60)
        avatars.forgetFailures()
        #expect(await avatars.image(for: unknown, pointSize: 16, scale: 2) == nil)
        #expect(server.requests("GET", "/u/e").count == 1)
        withExtendedLifetime(server) {}
    }

    @Test("the stand-in is recognized by its ETag, weak or strong, or by its body's SHA-256 without one")
    func standInRecognition() {
        let body = Data("not the stand-in".utf8)
        #expect(GitHubAvatarStandIn.matches(etag: "\"\(GitHubAvatarStandIn.digest)\"", body: body))
        #expect(GitHubAvatarStandIn.matches(etag: "W/\"\(GitHubAvatarStandIn.digest.uppercased())\"", body: body))
        #expect(!GitHubAvatarStandIn.matches(etag: "\"abc123\"", body: body))
        // Without an ETag, the body's SHA-256 decides.
        let bodyDigest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        #expect(!GitHubAvatarStandIn.matches(etag: nil, body: body))
        #expect(GitHubAvatarStandIn.matches(etag: nil, body: body, digest: bodyDigest))
        #expect(GitHubAvatarStandIn.matches(etag: "", body: body, digest: bodyDigest))
        // With one, the ETag does.
        #expect(!GitHubAvatarStandIn.matches(etag: "\"abc123\"", body: body, digest: bodyDigest))
    }

    // MARK: Failures

    @Test("a failure isn't tried again for 5 minutes; the next source is tried meanwhile")
    func failures() async throws {
        let server = MockGitHub()
        server.on("GET", "/u/1", respond: .status(500))
        server.on("GET", "/u/e", respond: image)
        let clock = TestClock()
        let avatars = loader(server, clock: clock)
        let joe = user("joe@example.com", avatarURL: "https://avatars.githubusercontent.com/u/1?v=4", endpoint: dotCom)

        // The API's URL fails; the email form loads.
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/u/1").count == 1)
        #expect(server.requests("GET", "/u/e").count == 1)
        // The failed one is skipped: the email form's image is the cached one.
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) != nil)
        clock.advance(by: 4 * 60 + 59)
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/u/1").count == 1)
        // Five minutes on, the API's URL is tried again first.
        clock.advance(by: 1)
        #expect(avatars.cachedImage(for: joe, pointSize: 16, scale: 2) == nil)
        _ = await avatars.image(for: joe, pointSize: 16, scale: 2)
        #expect(server.requests("GET", "/u/1").count == 2)
        withExtendedLifetime(server) {}
    }

    @Test("when the network comes back, failures are tried again at once, and the views are told")
    func networkReturns() async throws {
        let server = MockGitHub()
        server.on("GET", "/u/e", sequence: [.networkError(.notConnectedToInternet), image])
        let network = NetworkReturnMonitor(watchesPath: false)
        let avatars = loader(server, network: network)
        let joe = user("joe@example.com", endpoint: nil)
        let posts = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: GitHubAvatarLoader.networkDidReturn, object: network, queue: nil) { _ in
            posts.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) == nil)
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) == nil)
        #expect(server.requests("GET", "/u/e").count == 1)

        // The first path is how things are; going offline and back is a
        // return.
        network.pathChanged(satisfied: true)
        network.pathChanged(satisfied: true)
        #expect(posts.withLock { $0 } == 0)
        network.pathChanged(satisfied: false)
        network.pathChanged(satisfied: true)
        #expect(posts.withLock { $0 } == 1)
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/u/e").count == 2)
        withExtendedLifetime(server) {}
    }

    @Test("signing in forgets failures: an Enterprise Server in private mode answers with the token")
    func signingInRetries() async throws {
        let server = MockGitHub()
        server.on("GET", "/api/v3/enterprise/avatars/u/e") { request in
            request.header("Authorization") == nil ? .status(401) : image
        }
        let avatars = loader(server)
        let joe = user("joe@corp.example.com", endpoint: enterprise)

        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) == nil)
        avatars.setAccounts([GitHubFixtures.enterpriseAccount])
        #expect(await avatars.image(for: joe, pointSize: 16, scale: 2) != nil)
        #expect(server.requests("GET", "/api/v3/enterprise/avatars/u/e").count == 2)
        withExtendedLifetime(server) {}
    }
}
