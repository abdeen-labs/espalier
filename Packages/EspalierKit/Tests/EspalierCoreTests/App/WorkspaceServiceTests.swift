// Which links the workspace opens. A link from a server or a repository
// opens only as a web page or an email address; the workspace itself opens
// files, web pages, email addresses, and System Settings panes, and no
// other scheme.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import Testing
import TestSupport

@Suite("Workspace service") @MainActor
struct WorkspaceServiceTests {
    @Test("opens a link from a server or a repository only as a web page or an email address", arguments: [
        NamedCase("https", (url: "https://github.com/octocat/hello", opens: true)),
        NamedCase("http", (url: "http://ghe.example.com/octocat/hello", opens: true)),
        NamedCase("https, in capitals", (url: "HTTPS://github.com/octocat/hello", opens: true)),
        NamedCase("an app, as a file URL", (url: "file:///Applications/Calculator.app", opens: false)),
        NamedCase("a file", (url: "file:///Users/joe/espalier/README.md", opens: false)),
        NamedCase("a System Settings pane", (url: "x-apple.systempreferences:com.apple.Appearance-Settings.extension", opens: false)),
        NamedCase("mail", (url: "mailto:joe@example.com", opens: true)),
        NamedCase("another app's links", (url: "x-github-client://openRepo/https://github.com/octocat/hello", opens: false)),
        NamedCase("javascript", (url: "javascript:alert(1)", opens: false)),
        NamedCase("ssh", (url: "ssh://git@github.com/octocat/hello.git", opens: false)),
    ])
    func webLinks(_ testCase: NamedCase<(url: String, opens: Bool)>) throws {
        let url = try #require(URL(string: testCase.value.url))
        let workspace = RecordingWorkspace()
        #expect(workspace.openWebLink(url) == testCase.value.opens)
        #expect(workspace.openedURLs == (testCase.value.opens ? [url] : []))
    }

    @Test("opens files, web pages, email addresses, and System Settings panes, and no other links", arguments: [
        NamedCase("a file", (url: "file:///Users/joe/espalier/README.md", opens: true)),
        NamedCase("https", (url: "https://github.com/octocat/hello", opens: true)),
        NamedCase("http", (url: "http://ghe.example.com/octocat/hello", opens: true)),
        NamedCase("https, in capitals", (url: "HTTPS://github.com/octocat/hello", opens: true)),
        NamedCase("a System Settings pane", (url: "x-apple.systempreferences:com.apple.Appearance-Settings.extension", opens: true)),
        NamedCase("mail", (url: "mailto:joe@example.com", opens: true)),
        NamedCase("another app's links", (url: "x-github-client://openRepo/https://github.com/octocat/hello", opens: false)),
        NamedCase("an editor's links", (url: "vscode://file/Users/joe/espalier/README.md", opens: false)),
        NamedCase("javascript", (url: "javascript:alert(1)", opens: false)),
        NamedCase("ssh", (url: "ssh://git@github.com/octocat/hello.git", opens: false)),
        NamedCase("a file share", (url: "smb://server.example.com/share", opens: false)),
        NamedCase("ftp", (url: "ftp://example.com/x", opens: false)),
    ])
    func opens(_ testCase: NamedCase<(url: String, opens: Bool)>) throws {
        let url = try #require(URL(string: testCase.value.url))
        #expect(NSWorkspaceService.opens(url) == testCase.value.opens)
    }
}
