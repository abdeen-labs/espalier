// Ported from desktop/app/test/unit/find-upstream-remote-test.ts

@testable import EspalierCore
import GitKit
import TestSupport
import Testing

@Suite("findUpstreamRemote")
struct FindUpstreamRemoteTests {
    @Test("finds the upstream")
    func findsTheUpstream() throws {
        let parent = gitHubRepoFixture(owner: "somsubhra", name: "github-release-stats")
        let remotes = [
            Remote(name: "upstream", url: "https://github.com/Somsubhra/github-release-stats.git"),
        ]
        let upstream = try #require(findUpstreamRemote(parent, remotes))
        #expect(upstream.name == upstreamRemoteName)
        #expect(upstream.url == "https://github.com/Somsubhra/github-release-stats.git")
    }

    @Test("finds the upstream among other remotes, over SSH too")
    func amongOtherRemotes() {
        let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")
        let remotes = [
            Remote(name: "origin", url: "https://github.com/contributor/desktop.git"),
            Remote(name: "upstream", url: "git@github.com:desktop/desktop.git"),
        ]
        #expect(findUpstreamRemote(parent, remotes) == remotes[1])
    }

    @Test("needs a remote named exactly upstream")
    func needsTheName() {
        let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")
        #expect(findUpstreamRemote(parent, [Remote(name: "origin", url: "https://github.com/desktop/desktop.git")]) == nil)
        #expect(findUpstreamRemote(parent, [Remote(name: "Upstream", url: "https://github.com/desktop/desktop.git")]) == nil)
        #expect(findUpstreamRemote(parent, []) == nil)
    }

    @Test("ignores an upstream remote that points elsewhere")
    func pointsElsewhere() {
        let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")
        let remotes = [Remote(name: "upstream", url: "https://github.com/someone-else/desktop.git")]
        #expect(findUpstreamRemote(parent, remotes) == nil)
    }
}
