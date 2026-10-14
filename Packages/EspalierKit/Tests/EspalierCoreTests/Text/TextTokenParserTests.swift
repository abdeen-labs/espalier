// Ported from desktop/app/test/unit/text-token-parser-test.ts, less the
// emoji cases the other suites repeat. Plus forks, unknown web addresses,
// and code units.

@testable import EspalierCore
import GitHubKit
import Testing
import TestSupport

@Suite("Tokenizer")
struct TextTokenParserTests {
    /// The test table: `:shipit:`, one of GitHub's custom emoji.
    private static let testEmoji: [String: Emoji] = [
        ":shipit:": Emoji(emoji: nil, aliases: [":shipit:"]),
    ]

    private var emoji: [String: Emoji] {
        Self.testEmoji
    }

    private static let host = "https://github.com"
    private static let login = "shiftkey"
    private static let name = "some-repo"
    private static let htmlURL = "\(host)/\(login)/\(name)"

    private static let repository = RepositoryRecord(
        path: "some/path/to/repo",
        gitHubRepository: gitHubRepoFixture(owner: login, name: name, isPrivate: false)
    )

    private var gitHubTokenizer: Tokenizer {
        Tokenizer(emoji: emoji, repository: Self.repository)
    }

    /// A commit message with the repository's issue URL in it.
    private static let longMessage = """
        Note: we keep a "denylist" of authentication methods for which we do
        not want to enable http.emptyAuth automatically. An allowlist would be
        nicer, but less robust, as we want to support linking to several cURL
        versions and the list of authentication methods (as well as their names)
        changed over time.

        [jes: actually added the "auto" handling, excluded Digest, too]

        This fixes https://github.com/shiftkey/some-repo/issues/1034

        Signed-off-by: Johannes Schindelin <johannes.schindelin@gmx.de>
        """

    /// `longMessage` before its URL.
    private static let longMessageBefore = """
        Note: we keep a "denylist" of authentication methods for which we do
        not want to enable http.emptyAuth automatically. An allowlist would be
        nicer, but less robust, as we want to support linking to several cURL
        versions and the list of authentication methods (as well as their names)
        changed over time.

        [jes: actually added the "auto" handling, excluded Digest, too]

        This fixes
        """ + " "

    /// `longMessage` after its URL.
    private static let longMessageAfter = """


        Signed-off-by: Johannes Schindelin <johannes.schindelin@gmx.de>
        """

    @Suite("basic tests")
    struct BasicTests {
        @Test("tokenizes text and emoji", arguments: [
            NamedCase("preserves plain text string", (
                text: "this is a string without anything interesting",
                expected: [TokenResult.text("this is a string without anything interesting")]
            )),
            NamedCase("returns emoji between two string elements", (
                text: "let's :shipit: this thing",
                expected: [.text("let's "), .emoji(text: ":shipit:", emoji: nil), .text(" this thing")]
            )),
        ])
        func tokenizes(_ testCase: NamedCase<(text: String, expected: [TokenResult])>) {
            #expect(Tokenizer(emoji: testEmoji).tokenize(testCase.value.text) == testCase.value.expected)
        }
    }

    @Suite("with GitHub repository")
    struct WithGitHubRepository {
        @Test("links mentions, issue references, and the repository's issue URLs", arguments: [
            NamedCase("skips emoji when no match exists", (
                text: "releasing the thing :unknown:",
                expected: [TokenResult.text("releasing the thing :unknown:")]
            )),
            NamedCase("does not render link when email address found", (
                text: "the email address support@github.com should be ignored",
                expected: [.text("the email address support@github.com should be ignored")]
            )),
            NamedCase("render mention when text starts with a @", (
                text: "@\(login) was here",
                expected: [.link(text: "@shiftkey", url: "\(host)/\(login)"), .text(" was here")]
            )),
            NamedCase("renders mention when token found", (
                text: "fixed based on suggestion from @\(login)",
                expected: [.text("fixed based on suggestion from "), .link(text: "@shiftkey", url: "\(host)/\(login)")]
            )),
            NamedCase("ignores http prefix when no text after", (
                text: "fix double http:// in avatar URLs",
                expected: [.text("fix double http:// in avatar URLs")]
            )),
            NamedCase("renders link when an issue reference is found", (
                text: "Merge pull request #955 from desktop/computering-icons-for-all",
                expected: [
                    .text("Merge pull request "),
                    .link(text: "#955", url: "\(htmlURL)/issues/955"),
                    .text(" from desktop/computering-icons-for-all"),
                ]
            )),
            NamedCase("renders link when squash and merge", (
                text: "Update README.md (#5203)",
                expected: [
                    .text("Update README.md ("),
                    .link(text: "#5203", url: "\(htmlURL)/issues/5203"),
                    .text(")"),
                ]
            )),
            NamedCase("renders link and author mention when parsing release notes", (
                text: "'Clone repository' menu item label is obscured on Windows - #5348. Thanks @Daniel-McCarthy!",
                expected: [
                    .text("'Clone repository' menu item label is obscured on Windows - "),
                    .link(text: "#5348", url: "\(htmlURL)/issues/5348"),
                    .text(". Thanks "),
                    .link(text: "@Daniel-McCarthy", url: "https://github.com/Daniel-McCarthy"),
                    .text("!"),
                ]
            )),
            NamedCase("renders multiple issue links and mentions", (
                text: "Assorted changelog typos - #3174 #3184 #3207. Thanks @strafe, @alanaasmaa and @jt2k!",
                expected: [
                    .text("Assorted changelog typos - "),
                    .link(text: "#3174", url: "\(htmlURL)/issues/3174"),
                    .text(" "),
                    .link(text: "#3184", url: "\(htmlURL)/issues/3184"),
                    .text(" "),
                    .link(text: "#3207", url: "\(htmlURL)/issues/3207"),
                    .text(". Thanks "),
                    .link(text: "@strafe", url: "https://github.com/strafe"),
                    .text(", "),
                    .link(text: "@alanaasmaa", url: "https://github.com/alanaasmaa"),
                    .text(" and "),
                    .link(text: "@jt2k", url: "https://github.com/jt2k"),
                    .text("!"),
                ]
            )),
            NamedCase("renders multiple issue links and mentions even with commas", (
                text: "Assorted changelog typos - #3174, #3184 & #3207. Thanks @strafe, @alanaasmaa, and @jt2k!",
                expected: [
                    .text("Assorted changelog typos - "),
                    .link(text: "#3174", url: "\(htmlURL)/issues/3174"),
                    .text(", "),
                    .link(text: "#3184", url: "\(htmlURL)/issues/3184"),
                    .text(" & "),
                    .link(text: "#3207", url: "\(htmlURL)/issues/3207"),
                    .text(". Thanks "),
                    .link(text: "@strafe", url: "https://github.com/strafe"),
                    .text(", "),
                    .link(text: "@alanaasmaa", url: "https://github.com/alanaasmaa"),
                    .text(", and "),
                    .link(text: "@jt2k", url: "https://github.com/jt2k"),
                    .text("!"),
                ]
            )),
            NamedCase("converts full URL to issue shorthand", (
                text: longMessage,
                expected: [
                    .text(longMessageBefore),
                    .link(text: "#1034", url: "https://github.com/shiftkey/some-repo/issues/1034"),
                    .text(longMessageAfter),
                ]
            )),
        ])
        func tokenizes(_ testCase: NamedCase<(text: String, expected: [TokenResult])>) {
            let tokenizer = Tokenizer(emoji: testEmoji, repository: repository)
            #expect(tokenizer.tokenize(testCase.value.text) == testCase.value.expected)
        }
    }

    @Suite("with non-GitHub repository")
    struct WithNonGitHubRepository {
        @Test("renders plain links, and no mentions or issue references", arguments: [
            NamedCase("does not render link for mention", (
                text: "fixed based on suggestion from @shiftkey",
                expected: [TokenResult.text("fixed based on suggestion from @shiftkey")]
            )),
            NamedCase("does not render link for issue reference", (
                text: "Merge pull request #955 from desktop/computering-icons-for-all",
                expected: [.text("Merge pull request #955 from desktop/computering-icons-for-all")]
            )),
            // The text around the link is the same as with a GitHub repository.
            NamedCase("renders plain link for full URL", (
                text: longMessage,
                expected: [
                    .text(longMessageBefore),
                    .link(
                        text: "https://github.com/shiftkey/some-repo/issues/1034",
                        url: "https://github.com/shiftkey/some-repo/issues/1034"
                    ),
                    .text(longMessageAfter),
                ]
            )),
        ])
        func tokenizes(_ testCase: NamedCase<(text: String, expected: [TokenResult])>) {
            #expect(Tokenizer(emoji: testEmoji).tokenize(testCase.value.text) == testCase.value.expected)
        }
    }

    // MARK: Further cases

    @Test("a fork that contributes to its parent links issues and mentions there")
    func forkContributingToParent() {
        let parent = gitHubRepoFixture(owner: "upstream", name: "project")
        let fork = gitHubRepoFixture(owner: "me", name: "project", parent: parent)
        let record = RepositoryRecord(path: "some/path", gitHubRepository: fork)
        let results = Tokenizer(emoji: emoji, repository: record).tokenize("Fix #12")
        #expect(results == [.text("Fix "), .link(text: "#12", url: "https://github.com/upstream/project/issues/12")])
    }

    @Test("Enterprise mentions link to the server's profiles")
    func enterpriseMention() {
        let enterprise = gitHubRepoFixture(owner: "team", name: "tool", endpoint: "https://ghe.example.com/api/v3")
        let results = Tokenizer(emoji: emoji, gitHubRepository: enterprise).tokenize("thanks @octo")
        #expect(results == [.text("thanks "), .link(text: "@octo", url: "https://ghe.example.com/octo")])
    }

    @Test("ghe.com mentions link to the enterprise's profiles")
    func gheMention() {
        let enterprise = gitHubRepoFixture(owner: "team", name: "tool", endpoint: "https://api.acme.ghe.com/")
        let results = Tokenizer(emoji: emoji, gitHubRepository: enterprise).tokenize("thanks @octo")
        #expect(results == [.text("thanks "), .link(text: "@octo", url: "https://acme.ghe.com/octo")])
    }

    @Test("an issue reference stays text when the repository's web address isn't known")
    func issueWithoutHTMLURL() {
        let repository = GitHubRepository(name: "repo", owner: Owner(login: "owner", endpoint: getDotComAPIEndpoint(), id: 1), dbID: 1)
        let results = Tokenizer(emoji: emoji, gitHubRepository: repository).tokenize("Fix #12, thanks @someone")
        #expect(results == [.text("Fix #12, thanks "), .link(text: "@someone", url: "https://github.com/someone")])
    }

    @Test("issue numbers drop leading zeros; words that aren't references stay text")
    func issueEdgeCases() {
        #expect(gitHubTokenizer.tokenize("#007") == [.link(text: "#007", url: "\(Self.htmlURL)/issues/7")])
        #expect(gitHubTokenizer.tokenize("#12a #") == [.text("#12a #")])
        #expect(gitHubTokenizer.tokenize("a#12") == [.text("a"), .link(text: "#12", url: "\(Self.htmlURL)/issues/12")])
    }

    @Test("a URL after a word character, or another repository's issue URL, isn't shortened")
    func urlEdgeCases() {
        #expect(gitHubTokenizer.tokenize("(https://example.com)") == [.text("(https://example.com)")])
        let other = "https://github.com/someone/else/issues/3"
        #expect(gitHubTokenizer.tokenize(other) == [.link(text: other, url: other)])
        // The prefix compares without case; "/issues/" before the number doesn't.
        let upper = "https://GITHUB.COM/SHIFTKEY/SOME-REPO/Issues/9"
        #expect(gitHubTokenizer.tokenize(upper) == [.link(text: upper, url: upper)])
        // Only "http" in lowercase starts a link.
        let shouting = "HTTPS://GITHUB.COM"
        #expect(gitHubTokenizer.tokenize(shouting) == [.text(shouting)])
        let mixed = "https://GitHub.com/ShiftKey/some-repo/issues/9#issuecomment-1"
        #expect(gitHubTokenizer.tokenize(mixed) == [.link(text: "#9", url: mixed)])
    }

    @Test("a URL leaves out the punctuation ending a sentence or a parenthesis around it (desktop kept it)")
    func urlTrailingPunctuation() {
        let tokenizer = Tokenizer(emoji: emoji)
        #expect(tokenizer.tokenize("(see https://example.com/a).") == [
            .text("(see "), .link(text: "https://example.com/a", url: "https://example.com/a"), .text(")."),
        ])
        #expect(tokenizer.tokenize("Read https://example.com/wiki/Swift_(language), then") == [
            .text("Read "),
            .link(text: "https://example.com/wiki/Swift_(language)", url: "https://example.com/wiki/Swift_(language)"),
            .text(", then"),
        ])
        #expect(tokenizer.tokenize("Is it http://example.com?!") == [
            .text("Is it "), .link(text: "http://example.com", url: "http://example.com"), .text("?!"),
        ])
        // At least one character after the scheme stays a link's.
        #expect(tokenizer.tokenize("https://.") == [.link(text: "https://.", url: "https://.")])
        // The repository's issue URLs still shorten.
        #expect(gitHubTokenizer.tokenize("Fixes \(Self.htmlURL)/issues/3.") == [
            .text("Fixes "), .link(text: "#3", url: "\(Self.htmlURL)/issues/3"), .text("."),
        ])
    }

    @Test("issue references and mentions leave out the punctuation after them")
    func issueAndMentionTrailingPunctuation() {
        let issue = { (number: Int) in TokenResult.link(text: "#\(number)", url: "\(Self.htmlURL)/issues/\(number)") }
        let mention = { (login: String) in TokenResult.link(text: "@\(login)", url: "https://github.com/\(login)") }
        #expect(gitHubTokenizer.tokenize("Closes #12: done") == [.text("Closes "), issue(12), .text(": done")])
        #expect(gitHubTokenizer.tokenize("Update README.md (#5203).") == [.text("Update README.md ("), issue(5203), .text(").")])
        #expect(gitHubTokenizer.tokenize("Is it #3?") == [.text("Is it "), issue(3), .text("?")])
        #expect(gitHubTokenizer.tokenize("(cc @alice). Thanks @bob: done") == [
            .text("(cc "), mention("alice"), .text("). Thanks "), mention("bob"), .text(": done"),
        ])
        #expect(gitHubTokenizer.tokenize("ready, @carol?") == [.text("ready, "), mention("carol"), .text("?")])
    }

    @Test("a tab or carriage return ends a word")
    func tabAndCarriageReturnEndWords() {
        #expect(gitHubTokenizer.tokenize("Fixes #12\r\nby @alice\tthanks") == [
            .text("Fixes "),
            .link(text: "#12", url: "\(Self.htmlURL)/issues/12"),
            .text("\r\nby "),
            .link(text: "@alice", url: "https://github.com/alice"),
            .text("\tthanks"),
        ])
        #expect(Tokenizer(emoji: emoji).tokenize("see\thttps://example.com\r\n:shipit:\t") == [
            .text("see\t"),
            .link(text: "https://example.com", url: "https://example.com"),
            .text("\r\n"),
            .emoji(text: ":shipit:", emoji: nil),
            .text("\t"),
        ])
    }

    @Test("adjacent shortcodes: the scan restarts at each colon; emoji keep the text around them")
    func shortcodesAndUnicode() {
        let table = EmojiTable.all
        // ":tada::tada:" and "::tada:" aren't shortcodes; the last ":tada:" is.
        #expect(Tokenizer(emoji: table).tokenize(":tada::tada:") == [.text(":tada:"), .emoji(text: ":tada:", emoji: "\u{1F389}")])
        #expect(Tokenizer(emoji: table).tokenize("\u{1F600} :tada: caf\u{E9}") == [
            .text("\u{1F600} "),
            .emoji(text: ":tada:", emoji: "\u{1F389}"),
            .text(" caf\u{E9}"),
        ])
        // A shortcode compares by code units: the Kelvin sign isn't "K".
        let kelvin: [String: Emoji] = [":K:": Emoji(emoji: "k", aliases: ["K"])]
        #expect(Tokenizer(emoji: kelvin).tokenize(":\u{212A}:") == [.text(":\u{212A}:")])
        #expect(Tokenizer(emoji: kelvin).tokenize(":K:") == [.emoji(text: ":K:", emoji: "k")])
    }
}
