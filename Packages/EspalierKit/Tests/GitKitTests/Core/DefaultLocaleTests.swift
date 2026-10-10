// Git processes get the runtime's default locale as `LC_CTYPE` when their
// environment has none, so the hooks git runs itself and the programs it
// starts read and write UTF-8. Commands whose output depends on git's
// regex matching keep the environment as it is.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("The default locale")
struct DefaultLocaleTests {
    /// The environment git starts from, what the invocation adds, and the
    /// `LC_CTYPE` and `LANG` git gets.
    struct LocaleCase: Sendable {
        let processEnv: [String: String]
        let invocationEnv: [String: String?]
        let ctype: String?
        let lang: String?
    }

    static let cases: [NamedCase<LocaleCase>] = [
        NamedCase("no locale", LocaleCase(processEnv: [:], invocationEnv: [:], ctype: "de_DE.UTF-8", lang: nil)),
        NamedCase("empty values count as unset", LocaleCase(
            processEnv: ["LANG": "", "LC_ALL": "", "LC_CTYPE": ""], invocationEnv: [:], ctype: "de_DE.UTF-8", lang: ""
        )),
        NamedCase("LANG", LocaleCase(processEnv: ["LANG": "C.UTF-8"], invocationEnv: [:], ctype: nil, lang: "C.UTF-8")),
        NamedCase("LC_ALL", LocaleCase(processEnv: ["LC_ALL": "C"], invocationEnv: [:], ctype: nil, lang: nil)),
        NamedCase("LC_CTYPE", LocaleCase(processEnv: ["LC_CTYPE": "UTF-8"], invocationEnv: [:], ctype: "UTF-8", lang: nil)),
        NamedCase("LC_MESSAGES alone isn't a character set", LocaleCase(
            processEnv: ["LC_MESSAGES": "fr_FR.UTF-8"], invocationEnv: [:], ctype: "de_DE.UTF-8", lang: nil
        )),
        NamedCase("the invocation's LANG", LocaleCase(processEnv: [:], invocationEnv: ["LANG": "C"], ctype: nil, lang: "C")),
        NamedCase("the invocation removes LANG", LocaleCase(
            processEnv: ["LANG": "C.UTF-8"], invocationEnv: ["LANG": nil], ctype: "de_DE.UTF-8", lang: nil
        )),
    ]

    @Test("goes to LC_CTYPE only when the environment has no LANG, LC_ALL, or LC_CTYPE", arguments: cases)
    func setupEnvironment(_ test: NamedCase<LocaleCase>) {
        let (env, _) = Dugite.setupEnvironment(
            test.value.invocationEnv,
            processEnv: test.value.processEnv,
            gitDir: Dugite.resolveGitDir(TestEnvironment.runtime),
            defaultLocale: "de_DE.UTF-8"
        )
        #expect(env["LC_CTYPE"] == test.value.ctype)
        #expect(env["LANG"] == test.value.lang)
    }

    @Test("without one, nothing is added")
    func noDefaultLocale() {
        let (env, _) = Dugite.setupEnvironment([:], processEnv: [:], gitDir: Dugite.resolveGitDir(TestEnvironment.runtime))
        #expect(env["LC_CTYPE"] == nil)
        #expect(env["LANG"] == nil)
    }

    @Test("hooks git runs itself get it as LC_CTYPE, and no LANG, when the environment has no locale")
    func hooks() async throws {
        let repository = try setupEmptyRepository("main")
        let output = try createTempDirectory()
        for hook in ["post-checkout", "reference-transaction"] {
            try writeHook(repository, hook, """
                /usr/bin/env -0 > '\(output)/\(hook)'
                [ "\(hook)" = reference-transaction ] && cat > /dev/null
                exit 0
                """)
        }
        func seen(_ hook: String) throws -> [String: String] {
            let data = try Data(contentsOf: URL(filePath: POSIXPath.join(output, hook)))
            var variables: [String: String] = [:]
            for entry in data.split(separator: 0) {
                let text = String(decoding: entry, as: UTF8.self)
                if let separator = text.firstIndex(of: "=") {
                    variables[String(text[..<separator])] = String(text[text.index(after: separator)...])
                }
            }
            return variables
        }

        try await withLocale(nil, defaultLocale: "en_GB.UTF-8") {
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "a\n")], commitMessage: "First"))
            _ = try await git(["checkout", "-q", "-b", "topic"], repository.path, "checkout")
        }
        for hook in ["post-checkout", "reference-transaction"] {
            let variables = try seen(hook)
            #expect(variables["LC_CTYPE"] == "en_GB.UTF-8", "\(hook)")
            #expect(variables["LANG"] == nil, "\(hook)")
            #expect(variables["LC_ALL"] == nil, "\(hook)")
        }

        // A locale the environment has is left as it is.
        try await withLocale("pt_BR.UTF-8", defaultLocale: "en_GB.UTF-8") {
            _ = try await git(["checkout", "-q", "main"], repository.path, "checkout")
        }
        for hook in ["post-checkout", "reference-transaction"] {
            let variables = try seen(hook)
            #expect(variables["LANG"] == "pt_BR.UTF-8", "\(hook)")
            #expect(variables["LC_CTYPE"] == nil, "\(hook)")
        }
    }

    @Test("git matches regexes in it: its . matches a character, not a byte that isn't UTF-8")
    func gitRegexes() async throws {
        let repository = try setupEmptyRepository("main")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "a\n")], commitMessage: "\u{E9}"))
        let pattern = ["log", "--format=%s", "--grep=^.$"]
        let withoutLocale = try await withLocale(nil, defaultLocale: nil) {
            try await git(pattern, repository.path, "log").stdout
        }
        let withLocale = try await withLocale(nil, defaultLocale: "en_US.UTF-8") {
            try await git(pattern, repository.path, "log").stdout
        }
        #expect(withoutLocale.isEmpty)
        #expect(withLocale == "\u{E9}\n")
    }

    @Test("a remote whose name isn't UTF-8 is listed as without it")
    func remotes() async throws {
        let repository = try setupEmptyRepository("main")
        // remote.r<E9>.url, in Latin-1.
        let config = POSIXPath.join(repository.resolvedGitDir, "config")
        let handle = try FileHandle(forWritingTo: URL(filePath: config))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[remote \"r".utf8) + Data([0xE9]) + Data("\"]\n\turl = https://example.com/latin.git\n".utf8))
        try handle.write(contentsOf: Data("[remote \"origin\"]\n\turl = https://example.com/origin.git\n".utf8))
        try handle.close()

        let withoutLocale = try await withLocale(nil, defaultLocale: nil) { try await getRemotes(repository) }
        let withDefault = try await withLocale(nil, defaultLocale: "en_US.UTF-8") { try await getRemotes(repository) }
        #expect(withoutLocale.map(\.name) == ["origin", "r\u{FFFD}"])
        #expect(withDefault == withoutLocale)
    }

    @Test("a checkout of a branch whose name isn't UTF-8 counts as without it")
    func branchCheckouts() async throws {
        let repository = try setupEmptyRepository("main")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "a\n")], commitMessage: "First"))
        let head = try await git(["rev-parse", "HEAD"], repository.path, "revParse").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // HEAD's reflog entries as checking out a branch with a Latin-1 name,
        // and one with a UTF-8 name, would write them.
        try appendReflog(repository, head, message: Data("checkout: moving from main to caf".utf8) + Data([0xE9]))
        try appendReflog(repository, head, message: Data("checkout: moving from caf\u{E9} to main".utf8))

        let date = Date(timeIntervalSince1970: 0)
        let withoutLocale = try await withLocale(nil, defaultLocale: nil) { try await getBranchCheckouts(repository, date) }
        let withDefault = try await withLocale(nil, defaultLocale: "en_US.UTF-8") { try await getBranchCheckouts(repository, date) }
        #expect(Set(withoutLocale.keys) == ["caf\u{FFFD}", "main"])
        #expect(withDefault == withoutLocale)
    }
}

/// Runs `operation` with `LANG` set to `lang` (nil: no locale at all) and
/// the runtime's `defaultLocale`, for the current task only.
private func withLocale<T>(
    _ lang: String?,
    defaultLocale: String?,
    _ operation: () async throws -> T
) async throws -> T {
    var runtime = TestEnvironment.runtime
    for name in ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LANGUAGE"] {
        runtime.processEnvironment[name] = nil
    }
    runtime.processEnvironment["LANG"] = lang
    runtime.defaultLocale = defaultLocale
    return try await GitRuntime.withRuntime(runtime) {
        try await operation()
    }
}

/// Appends an entry with `message` to HEAD's reflog, from and to `sha`.
private func appendReflog(_ repository: Repository, _ sha: String, message: Data) throws {
    let path = POSIXPath.join(repository.resolvedGitDir, "logs/HEAD")
    let handle = try FileHandle(forWritingTo: URL(filePath: path))
    try handle.seekToEnd()
    let identity = "Joe Bloggs <joe.bloggs@somewhere.com> \(Int(Date().timeIntervalSince1970)) +0000"
    try handle.write(contentsOf: Data("\(sha) \(sha) \(identity)\t".utf8) + message + Data("\n".utf8))
    try handle.close()
}
