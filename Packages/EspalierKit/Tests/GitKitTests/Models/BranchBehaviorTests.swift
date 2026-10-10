@testable import GitKit
import Testing

@Suite("Branch behavior")
struct BranchBehaviorTests {
    @Test("the remote names split as their regular expressions do, line terminators and all")
    func remoteNamesMatchPatterns() {
        let texts = [
            "origin/main", "origin/feature/x", "main", "", "/", "//", "/x", "x/", "a b/c",
            "\u{E9}/\u{FC}", "\u{1F680}/x", "x/\u{1F680}", "a/\u{301}b", "e\u{301}/x", "/\u{301}", "\u{600}/x", "x/\u{600}y",
            "a\u{0}b/c", "\u{FEFF}/x", "a\u{85}b/c", "a\u{B}b/c", "a\u{C}/b", "a\u{2027}b/c", "a\u{20A8}/b", "a\u{2003}/b",
            "a\nb/c", "a/b\nc", "a\rb/c", "a/b\r", "a\r\n/b", "a\u{2028}b/c", "a/b\u{2029}", "\u{2029}/", "\n", "\r/",
            "refs/remotes/origin/main", "refs/remotes//x", "refs/remotes/origin", "refs/remotes/", "refs/remotesX/a/b",
            "refs/remotes/a\nb/c", "refs/remotes/a/b\u{2028}c", "refs/remotes/o\u{2028}/x", "\nrefs/remotes/a/b",
            "refs/heads/x", "REFS/remotes/a/b", "refs/remotes/\u{E9}/\u{FC}", "refs/remotes/\u{301}/x", "refs/remotes/o/\u{301}",
        ]
        for text in texts {
            for candidate in [text, "origin/\(text)", "refs/remotes/\(text)", "\(text)/\(text)"] {
                let label = candidate.debugDescription
                let expectedRemoteName = candidate.isEmpty ? nil : Branch.upstreamRemoteNameMatchingPattern(candidate)
                #expect(branch(upstream: candidate).upstreamRemoteName == expectedRemoteName, "\(label)")
                #expect(removeRemotePrefix(candidate) == removeRemotePrefixMatchingPattern(candidate), "\(label)")
                #expect(Branch.remoteName(ofRef: candidate) == Branch.remoteNameMatchingPattern(candidate), "\(label)")
                let remote = branch(candidate, type: .remote, ref: candidate)
                #expect((try? remote.remoteName) == Branch.remoteNameMatchingPattern(candidate), "\(label)")
            }
        }
    }

    @Test("upstreamRemoteName is everything before the first slash")
    func upstreamRemoteName() {
        #expect(branch(upstream: "origin/main").upstreamRemoteName == "origin")
        #expect(branch(upstream: "origin/feature/x").upstreamRemoteName == "origin")
        #expect(branch(upstream: nil).upstreamRemoteName == nil)
        #expect(branch(upstream: "").upstreamRemoteName == nil)
        #expect(branch(upstream: "main").upstreamRemoteName == nil)
        #expect(branch(upstream: "/main").upstreamRemoteName == "")
    }

    @Test("remoteName comes from the ref of a remote branch")
    func remoteName() throws {
        #expect(try branch("origin/main", type: .remote, ref: "refs/remotes/origin/main").remoteName == "origin")
        #expect(try branch("main", type: .local, ref: "refs/heads/main").remoteName == nil)
    }

    @Test("remoteName throws for a remote branch with an unexpected ref")
    func remoteNameThrows() {
        let malformed = branch("main", type: .remote, ref: "refs/heads/main")
        #expect(throws: ModelError("Remote branch ref has unexpected format: refs/heads/main")) {
            try malformed.remoteName
        }
    }

    @Test("upstreamWithoutRemote drops the remote")
    func upstreamWithoutRemote() {
        #expect(branch(upstream: "origin/feature/x").upstreamWithoutRemote == "feature/x")
        #expect(branch(upstream: "").upstreamWithoutRemote == nil)
        #expect(branch(upstream: nil).upstreamWithoutRemote == nil)
        #expect(branch(upstream: "main").upstreamWithoutRemote == nil)
    }

    @Test("nameWithoutRemote falls back to the name")
    func nameWithoutRemote() {
        #expect(branch("feature/x", type: .local, ref: "refs/heads/feature/x").nameWithoutRemote == "feature/x")
        #expect(branch("origin/feature/x", type: .remote, ref: "refs/remotes/origin/feature/x").nameWithoutRemote == "feature/x")
        #expect(branch("origin/", type: .remote, ref: "refs/remotes/origin/").nameWithoutRemote == "origin/")
        #expect(branch("main", type: .remote, ref: "refs/remotes/main").nameWithoutRemote == "main")
    }

    @Test("fork remotes are named espalier-<owner>, and their remote branches recognized with desktop's github-desktop- ones")
    func forkRemotes() {
        #expect(forkPullRequestRemoteName("octocat") == "espalier-octocat")
        #expect(isForkedRemoteName("espalier-octocat"))
        #expect(isForkedRemoteName("github-desktop-octocat"))
        #expect(!isForkedRemoteName("origin"))
        #expect(!isForkedRemoteName("my-espalier-octocat"))
        for name in [forkPullRequestRemoteName("foo") + "/main", "github-desktop-octocat/main"] {
            #expect(branch(name, type: .remote, ref: "refs/remotes/\(name)").isDesktopForkRemoteBranch)
            // A local branch with the same name isn't one.
            #expect(!branch(name, type: .local, ref: "refs/heads/\(name)").isDesktopForkRemoteBranch)
        }
        #expect(!branch("origin/espalier-main", type: .remote, ref: "refs/remotes/origin/espalier-main").isDesktopForkRemoteBranch)
    }

    private func branch(
        _ name: String = "x",
        upstream: String? = nil,
        type: BranchType = .local,
        ref: String = "refs/heads/x"
    ) -> Branch {
        Branch(name: name, upstream: upstream, tip: BranchTip(sha: "s"), type: type, ref: ref)
    }
}
