// `posixShellQuote` round-trips through /bin/sh: what `printf %s` prints for
// the quoted word is the word, byte for byte.

import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport

@Suite("posixShellQuote")
struct POSIXShellQuoteTests {
    /// What `/bin/sh -c <command>` writes to standard output, and how it ended.
    private static func runShell(_ command: String) async throws -> (termination: ChildProcess.Termination, stdout: Data) {
        let stdout = Mutex(Data())
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        child.observeStandardOutput { chunk in stdout.withLock { $0.append(chunk) } }
        let termination = await child.waitUntilExit()
        return (termination, stdout.withLock { $0 })
    }

    @Test("the shell reads back the quoted word exactly", .hangGuard(minutes: 5), arguments: [
        NamedCase("a plain word", "espalier"),
        NamedCase("an empty word", ""),
        NamedCase("spaces", "My Apps/Espalier copy.app"),
        NamedCase("a quote", "it's"),
        NamedCase("quotes only", "''"),
        // As a `Character`, the quote and the mark are one, which a
        // `replacingOccurrences(of: "'", ...)` misses.
        NamedCase("a quote followed by a combining mark", "a'\u{301}b"),
        NamedCase("a quote followed by a combining mark, then a command", "x'\u{301}; echo pwned; '"),
        NamedCase("command substitution", "$(echo pwned)"),
        NamedCase("backticks", "`echo pwned`"),
        NamedCase("variables", "$HOME ${PATH}"),
        NamedCase("newlines", "one\ntwo\n"),
        NamedCase("backslashes and double quotes", #"a\b"c\"#),
        NamedCase("globs", "* ? [a]"),
        NamedCase("non-ASCII", "Espalier é ü 日本 🌳"),
        NamedCase("decomposed non-ASCII", "e\u{301}cole"),
    ])
    func roundTrips(_ testCase: NamedCase<String>) async throws {
        let word = testCase.value
        let (termination, stdout) = try await Self.runShell("printf %s \(posixShellQuote(word))")
        #expect(termination == .exit(0))
        #expect(stdout == Data(word.utf8))
    }
}
