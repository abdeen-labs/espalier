import GitKit
import Testing

private func branch(
    _ name: String,
    sha: String = "deadbeef",
    upstream: String? = nil,
    type: BranchType = .local
) -> Branch {
    Branch(
        name: name,
        upstream: upstream,
        tip: BranchTip(sha: sha),
        type: type,
        ref: type == .local ? "refs/heads/\(name)" : "refs/remotes/\(name)"
    )
}

@Suite("models/tip")
struct TipTests {
    @Test("tipEquals compares the state each kind carries")
    func equality() {
        #expect(tipEquals(.unknown, .unknown))
        #expect(tipEquals(.unborn(ref: "main"), .unborn(ref: "main")))
        #expect(!tipEquals(.unborn(ref: "main"), .unborn(ref: "master")))
        #expect(tipEquals(.detached(currentSha: "abc"), .detached(currentSha: "abc")))
        #expect(!tipEquals(.detached(currentSha: "abc"), .detached(currentSha: "abd")))
        #expect(!tipEquals(.unknown, .unborn(ref: "main")))
        #expect(!tipEquals(.detached(currentSha: "deadbeef"), .valid(branch: branch("main"))))

        #expect(tipEquals(.valid(branch: branch("main")), .valid(branch: branch("main"))))
        #expect(!tipEquals(.valid(branch: branch("main")), .valid(branch: branch("main", sha: "cafebabe"))))
        #expect(!tipEquals(
            .valid(branch: branch("main", upstream: "origin/main")),
            .valid(branch: branch("main", upstream: "upstream/main"))
        ))
        #expect(!tipEquals(.valid(branch: branch("main", upstream: "origin/main")), .valid(branch: branch("main"))))
    }

    // Two branches at the same commit differ by name.
    @Test("tipEquals tells apart two branches at the same commit")
    func differentBranchesSameCommit() {
        #expect(!tipEquals(.valid(branch: branch("main")), .valid(branch: branch("copy-of-main"))))
        #expect(!tipEquals(
            .valid(branch: branch("main", upstream: "origin/main")),
            .valid(branch: branch("other", upstream: "origin/main"))
        ))
    }

    @Test("tipEquals compares names exactly")
    func exactNames() {
        #expect(!tipEquals(.unborn(ref: "caf\u{E9}"), .unborn(ref: "cafe\u{301}")))
        #expect(!tipEquals(.valid(branch: branch("caf\u{E9}")), .valid(branch: branch("cafe\u{301}"))))
    }
}
