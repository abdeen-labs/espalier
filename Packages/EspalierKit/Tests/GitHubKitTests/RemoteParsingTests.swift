// Ported from desktop/app/test/unit/remote-parsing-test.ts

@testable import GitHubKit
import TestSupport
import Testing

private func expectRemote(
    _ url: String,
    hostname: String,
    owner: String,
    name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let remote = parseRemote(url) else {
        Issue.record("Expected \(url) to parse", sourceLocation: sourceLocation)
        return
    }
    #expect(remote.hostname == hostname, sourceLocation: sourceLocation)
    #expect(remote.owner == owner, sourceLocation: sourceLocation)
    #expect(remote.name == name, sourceLocation: sourceLocation)
}

@Suite("URL remote parsing")
struct RemoteParsingTests {
    @Test("parses HTTPS URLs with a trailing git suffix")
    func httpsWithGitSuffix() {
        expectRemote("https://github.com/hubot/repo.git", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses HTTPS URLs with a trailing -git and .git suffixes")
    func httpsWithBothSuffixes() {
        expectRemote("https://github.com/hubot/repo-git.git", hostname: "github.com", owner: "hubot", name: "repo-git")
    }

    @Test("parses HTTPS URLs without a trailing git suffix")
    func httpsWithoutGitSuffix() {
        expectRemote("https://github.com/hubot/repo", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses HTTPS URLs with a trailing slash")
    func httpsWithTrailingSlash() {
        expectRemote("https://github.com/hubot/repo/", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses HTTPS URLs which include a username")
    func httpsWithUsername() {
        expectRemote("https://monalisa@github.com/hubot/repo.git", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs")
    func ssh() {
        expectRemote("git@github.com:hubot/repo.git", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs with custom username")
    func sshWithCustomUsername() {
        expectRemote("niik@niik.ghe.com:hubot/repo.git", hostname: "niik.ghe.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs without the git suffix")
    func sshWithoutGitSuffix() {
        expectRemote("git@github.com:hubot/repo", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs with the .git suffix and -git suffix")
    func sshWithBothSuffixes() {
        expectRemote("git@github.com:hubot/repo-git.git", hostname: "github.com", owner: "hubot", name: "repo-git")
    }

    @Test("parses SSH URLs with a trailing slash")
    func sshWithTrailingSlash() {
        expectRemote("git@github.com:hubot/repo/", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses git URLs")
    func git() {
        expectRemote("git:github.com/hubot/repo.git", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses git URLs without the git suffix")
    func gitWithoutGitSuffix() {
        expectRemote("git:github.com/hubot/repo", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses git URLs with a trailing slash")
    func gitWithTrailingSlash() {
        expectRemote("git:github.com/hubot/repo/", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs with the ssh prefix")
    func sshWithPrefix() {
        expectRemote("ssh://git@github.com/hubot/repo", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("parses SSH URLs with the ssh prefix and trailing slash")
    func sshWithPrefixAndTrailingSlash() {
        expectRemote("ssh://git@github.com/hubot/repo/", hostname: "github.com", owner: "hubot", name: "repo")
    }

    @Test("does not parse invalid HTTP URLs when missing repo name")
    func invalidHTTPWithoutName() {
        #expect(parseRemote("https://github.com/someuser//") == nil)
    }

    @Test("does not parse invalid SSH URLs when missing repo name ")
    func invalidSSHWithoutName() {
        #expect(parseRemote("git@github.com:hubot/") == nil)
    }

    @Test("does not parse invalid git URLs when missing repo name")
    func invalidGitWithoutName() {
        #expect(parseRemote("git:github.com/hubot/") == nil)
    }

    @Test("does not parse invalid HTTP URLs when missing repo owner")
    func invalidHTTPWithoutOwner() {
        #expect(parseRemote("https://github.com//somerepo") == nil)
    }

    @Test("does not parse invalid SSH URLs when missing repo owner")
    func invalidSSHWithoutOwner() {
        #expect(parseRemote("git@github.com:/somerepo") == nil)
    }

    @Test("does not parse invalid git URLs when missing repo owner")
    func invalidGitWithoutOwner() {
        #expect(parseRemote("git:github.com//somerepo") == nil)
    }

    @Test("drops .git/ from SSH and git URLs", arguments: [
        ("git@github.com:hubot/repo.git/", "github.com"),
        ("niik@niik.ghe.com:hubot/repo.git/", "niik.ghe.com"),
        ("ssh://git@github.com/hubot/repo.git/", "github.com"),
        ("git:github.com/hubot/repo.git/", "github.com"),
    ])
    func sshWithGitSuffixAndSlash(url: String, hostname: String) {
        expectRemote(url, hostname: hostname, owner: "hubot", name: "repo")
    }

    @Test("ends an HTTPS URL's user info before its path", arguments: [
        NamedCase("an @ in the path stays in the host", (url: "https://evil.example/x@github.com/hubot/repo.git", hostname: "evil.example/x@github.com")),
        NamedCase("user info ends at its last @", (url: "https://me@example.com@github.com/hubot/repo.git", hostname: "github.com")),
        NamedCase("user info with a password", (url: "https://me:secret@github.com:8443/hubot/repo.git", hostname: "github.com:8443")),
    ])
    func httpsUserInfo(_ testCase: NamedCase<(url: String, hostname: String)>) {
        expectRemote(testCase.value.url, hostname: testCase.value.hostname, owner: "hubot", name: "repo")
    }
}

@Suite("repository identifier parsing")
struct RepositoryIdentifierParsingTests {
    @Test("drops .git from an owner/name shortcut")
    func shortcutWithGitSuffix() throws {
        let identifier = try #require(parseRepositoryIdentifier("hubot/repo.git"))
        #expect(identifier == RepositoryIdentifier(hostname: nil, owner: "hubot", name: "repo"))
        #expect(parseRepositoryIdentifier("hubot/.git") == nil)
    }
}
